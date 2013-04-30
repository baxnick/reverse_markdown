require 'digest'

module ReverseMarkdown
  class Mapper
    attr_accessor :raise_errors
    attr_accessor :log_enabled, :log_level
    attr_accessor :li_counter
    attr_accessor :github_style_code_blocks
    attr_accessor :implicit_code_blocks
    attr_accessor :implicit_code_length

    def initialize(opts={})
      self.log_level   = :info
      self.log_enabled = true
      self.li_counter  = 0
      self.github_style_code_blocks = opts[:github_style_code_blocks] || false
      self.implicit_code_blocks = opts[:implicit_code_blocks] || false
      self.implicit_code_length  = opts[:implicit_code_length] || 60
    end

    def process_root(element)
      return '' if element.nil?

      markdown = process_element(element)  # recursively process all elements to get full markdown

      # Extract github style code blocks
      extractions = {}
      markdown.gsub!(%r{```.*?```}m) do |match|
        md5 = Digest::MD5.hexdigest(match)
        extractions[md5] = match
        "{code-block-extraction-#{md5}}"
      end

      markdown = markdown.split("\n").map do |line|
        if line.match(/^( {4}|\t)/)
          line
        else
          "#{ '  ' if line.match(/^ {2,3}/) }" +
          normalize_whitespace(line).strip +
          "#{ '  ' if line.match(/ {2}$/) }"
        end
      end.join("\n")

      markdown.gsub!(/\n{3,}/, "\n\n")

      # Insert pre block extractions
      markdown.gsub!(/\{code-block-extraction-([0-9a-f]{32})\}/){ extractions[$1] }

      markdown
    end

    def process_element(element)
      parent = element.parent ? element.parent.name.to_sym : nil
      output = ''

      if element.text?
        text = process_text(element)
        if output.end_with?(' ') && text.start_with?(' ')
          output << text.lstrip
        else
          output << text
        end
      else
        incoming = opening(element).to_s
        incoming.lstrip! if parent == :li
        output << incoming

        markdown_chunks = element.children.map { |child| process_element(child) }
        remove_adjacent_whitespace!(markdown_chunks)
        incoming = markdown_chunks.join
        incoming.strip! if [:b, :strong, :em, :i].include? element.name.to_sym
        output << incoming

        incoming = ending(element).to_s
        output << incoming
      end
      output
    end

    private

    # removes whitespace-only chunk if the previous chunk ends with whitespace
    def remove_adjacent_whitespace!(chunks)
      (chunks.size - 1).downto(1).each do |i|
        chunk = chunks[i]
        previous_chunk = chunks[i-1]
        chunks.delete_at(i) if chunk == ' ' && previous_chunk.end_with?(' ')
      end
    end

    def opening(element)
      parent = element.parent ? element.parent.name.to_sym : nil
      case element.name.to_sym
        when :html, :body
          ""
        when :li
          indent = '  ' * [(element.ancestors('ol').count + element.ancestors('ul').count - 1), 0].max
          if parent == :ol
            "#{indent}#{self.li_counter += 1}. "
          else
            "#{indent}- "
          end
        when :pre
          "\n"
        when :ol
          self.li_counter = 0
          "\n"
        when :ul, :root#, :p
          "\n"
        when :div
          if element.attr('class')
            "\n<div markdown=\"1\" class=\"#{element.attr('class')}\">\n"
          else
            "\n"
          end
        when :p
          if element.ancestors.map(&:name).include?('blockquote')
            "\n\n> "
          elsif [nil, :body].include? parent
            is_first = true
            previous = element.previous
            while is_first == true and previous do
              is_first = false unless previous.content.strip == "" || previous.text?
              previous = previous.previous
            end
            is_first ? "" : "\n\n"
          else
            "\n\n"
          end
        when :h1, :h2, :h3, :h4, :h5, :h6 # /h(\d)/ for 1.9
          element.name =~ /h(\d)/
          "\n" + ('#' * $1.to_i) + ' '
        when :em, :i
          substitute_em(element, parent)
        when :strong, :b
          substitute_b(element, parent)
        when :blockquote
          "> "
        when :code
          " #{handle_code_block parent, element}"
        when :a
          if !element.text.strip.empty? && element['href'] && !element['href'].start_with?('#')
            " ["
          else
            " "
          end
        when :img
          " !["
        when :hr
          "\n* * *\n"
        when :br
          "  \n"
        else
          handle_error "unknown start tag: #{element.name.to_s}"
          ""
      end
    end

    def ending(element)
      parent = element.parent ? element.parent.name.to_sym : nil
      case element.name.to_sym
        when :html, :body, :pre, :hr
          ""
        when :p
          "\n\n"
        when :div
          if element.attr('class')
            "\n</div>\n"
          else
            "\n"
          end
        when :h1, :h2, :h3, :h4, :h5, :h6 # /h(\d)/ for 1.9
          "\n"
        when :em, :i
          substitute_em(element, parent)
        when :strong, :b
          substitute_b(element, parent)
        when :li, :blockquote, :root, :ol, :ul
          "\n"
        when :code
          "#{handle_code_block parent, element} "
        when :a
          if !element.text.strip.empty? && element['href'] && !element['href'].start_with?('#')
            "](#{element['href']}#{title_markdown(element)})"
          else
            ""
          end
        when :img
          "#{element['alt']}](#{element['src']}#{title_markdown(element)}) "
        else
          handle_error "unknown end tag: #{element.name}"
          ""
      end
    end

    def title_markdown(element)
      title = element['title']
      title ? %[ "#{title}"] : ''
    end

    def process_text(element)
      parent = element.parent ? element.parent.name.to_sym : nil
      case
        when parent == :code
          if self.github_style_code_blocks
            element.text
          else
            element.text.strip.gsub(/\n/,"\n    ")
          end
        else
          normalize_whitespace(escape_text(element.text))
      end
    end

    def normalize_whitespace(text)
      text.tr("\n\t", ' ').squeeze(' ')
    end

    def escape_text(text)
      text.
        gsub('*', '\*').
        gsub('_', '\_')
    end

    def handle_error(message)
      if raise_errors
        raise ReverseMarkdown::ParserError, message
      elsif log_enabled && defined?(Rails)
        Rails.logger.__send__(log_level, message)
      end
    end

    def handle_code_block(parent, element)
      if parent == :pre or is_implicit_code_block element
        self.github_style_code_blocks ? "\n```\n" : "\n    "
      else
        "`"
      end
    end

    def is_implicit_code_block(element)
      return false unless implicit_code_blocks

      /^\s*\n/.match element.text or
      element.text.length > self.implicit_code_length
    end

    def substitute_em(element, parent)
      substitution = parent == :code ? '%%em%%' : '*'
      if element.text.strip.empty? or not (element.ancestors('em') + element.ancestors('i')).empty?
        ''
      else
        substitution if (element.ancestors('em') + element.ancestors('i')).empty?
      end
    end

    def substitute_b(element, parent)
      substitution = parent == :code ? '%%b%%' : '**'
      if element.text.strip.empty? or not (element.ancestors('strong') + element.ancestors('b')).empty?
        ''
      else
        substitution if (element.ancestors('strong') + element.ancestors('b')).empty?
      end
    end
  end
end
