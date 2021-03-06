require 'securerandom'
require 'rainforest'
require 'parallel'
require 'ruby-progressbar'

class RainforestCli::TestImporter
  attr_reader :options, :client
  SPEC_FOLDER = 'spec/rainforest'.freeze
  EXT = ".rfml".freeze
  THREADS = 32.freeze

  SAMPLE_FILE = <<EOF
#! %s (this is the ID, don't edit it)
# title: New test
#
# 1. steps:
#   a) pairs of lines are steps (first line = action, second = response)
#   b) second line must have a ?
#   c) second line must not be blank
# 2. comments:
#   a) lines starting # are comments
#

EOF

  def initialize(options)
    @options = options
    unless File.exists?(SPEC_FOLDER)
      logger.fatal "Rainforest folder not found (#{SPEC_FOLDER})"
      exit 2
    end
  end

  def logger
    RainforestCli.logger
  end

  def export
    ::Rainforest.api_key = @options.token

    tests = Rainforest::Test.all(page_size: 1000)
    p = ProgressBar.create(title: 'Rows', total: tests.count, format: '%a %B %p%% %t')
    Parallel.each(tests, in_threads: THREADS, finish: lambda { |item, i, result| p.increment }) do |test|

      # File name
      file_name = sprintf('%010d', test.id) + "_" + test.title.strip.gsub(/[^a-z0-9 ]+/i, '').gsub(/ +/, '_').downcase
      file_name = create_new(file_name)
      File.truncate(file_name, 0)

      # Get the full test from the API
      test = Rainforest::Test.retrieve(test.id)

      File.open(file_name, 'a') do |file|
        file.puts _get_header(test)

        index = 0
        test.elements.each do |element|
          index = _process_element(file, element, index)
        end
      end
    end
  end

  def _process_element file, element, index
    case element[:type]
    when 'test'
      element[:element][:elements].each do |sub_element|
        index = _process_element(file, sub_element, index)
      end
    when 'step'
      file.puts "" unless index == 0
      file.puts "# step #{index + 1}" if @options.debug
      file.puts element[:element][:action]
      file.puts element[:element][:response]
    else
      raise "Unknown element type: #{element[:type]}"
    end

    index += 1
    index
  end

  # add comments if not already present
  def _get_header test
    out = []

    has_id = false
    test.description.to_s.strip.lines.map(&:chomp).each_with_index do |line, line_no|
      line = line.gsub(/\#+$/, '').strip

      # make sure the test has an ID
      has_id = true if line[0] == "!"

      out << "#" + line
    end

    unless has_id
      browsers = test.browsers.map {|b| b[:name] if b[:state] == "enabled" }.compact
      out = ["#! #{SecureRandom.uuid}", "# title: #{test.title}", "# start_uri: #{test.start_uri}", "# tags: #{test.tags.join(", ")}", "# browsers: #{browsers.join(", ")}", "#", " "] + out
    end

    out.compact.join("\n")
  end

  def _get_id test
    id = nil
    test.description.to_s.strip.lines.map(&:chomp).each_with_index do |line, line_no|
      line = line.gsub(/\#+$/, '').strip
      if line[0] == "!"
        id = line[1..-1].split(' ').first
        break
      end
    end
    id
  end

  def upload
    ::Rainforest.api_key = @options.token

    ids = {}
    logger.info "Syncing tests"
    Rainforest::Test.all(page_size: 1000).each do |test|
      id = _get_id(test)

      next if id.nil?

      # note, this test id is numeric
      ids[id] = test.id
    end

    logger.debug ids.inspect if @options.debug

    tests = validate.values

    logger.info "Uploading tests..."
    p = ProgressBar.create(title: 'Rows', total: tests.count, format: '%a %B %p%% %t')

    # Insert the data
    Parallel.each(tests, in_threads: THREADS, finish: lambda { |item, i, result| p.increment }) do |test|
      next unless test.steps.count > 0

      if @options.debug
        logger.debug "Starting: #{test.id}"
        logger.debug "\t#{test.start_uri || "/"}"
      end

      test_obj = {
        start_uri: test.start_uri || "/",
        title: test.title,
        description: test.description,
        tags: (["ro"] + test.tags).uniq,
        elements: test.steps.map do |step|
          {type: 'step', redirection: true, element: {
            action: step.action,
            response: step.response
          }}
        end
      }

      unless test.browsers.empty?
        test_obj[:browsers] = test.browsers.map {|b|
          {'state' => 'enabled', 'name' => b}
        }
      end

      # Create the test
      begin
        if ids[test.id]
          t = Rainforest::Test.update(ids[test.id], test_obj)

          logger.info "\tUpdated #{test.id} -- ##{t.id}" if @options.debug
        else
          t = Rainforest::Test.create(test_obj)

          logger.info "\tCreated #{test.id} -- ##{t.id}" if @options.debug
        end
      rescue => e
        logger.fatal "Error: #{test.id}: #{e}"
        exit 2
      end
    end
  end

  def validate
    tests = {}
    has_errors = []

    Dir.glob("#{SPEC_FOLDER}/**/*#{EXT}").each do |file_name|
      out = RainforestCli::TestParser::Parser.new(File.read(file_name)).process

      tests[file_name] = out
      has_errors << file_name if out.errors != {}
    end

    if !has_errors.empty?
      logger.error "Parsing errors:"
      logger.error ""
      has_errors.each do |file_name|
        logger.error " " + file_name
        tests[file_name].errors.each do |line, error|
          logger.error "\t#{error.to_s}"
        end
      end

      exit 2
    end

    if @options.debug
      tests.each do |file_name,test|
        logger.debug test.inspect
        logger.debug "#{file_name}"
        logger.debug test.description
        test.steps.each do |step|
          logger.debug "\t#{step}"
        end
      end
    else
      logger.info "[VALID]"
    end

    return tests
  end

  def create_new file_name = nil
    name = @options.file_name if @options.file_name
    name = file_name if !file_name.nil?

    uuid = SecureRandom.uuid
    name = "#{uuid}#{EXT}" unless name
    name += EXT unless name[-EXT.length..-1] == EXT
    name = File.join([SPEC_FOLDER, name])

    File.open(name, "w") { |file| file.write(sprintf(SAMPLE_FILE, uuid)) }

    logger.info "Created #{name}" if file_name.nil?
    name
  end
end
