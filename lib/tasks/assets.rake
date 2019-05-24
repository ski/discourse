# frozen_string_literal: true

task 'assets:precompile:before' do

  require 'uglifier'
  require 'open3'

  unless %w{profile production}.include? Rails.env
    raise "rake assets:precompile should only be run in RAILS_ENV=production, you are risking unminified assets"
  end

  # Ensure we ALWAYS do a clean build
  # We use many .erbs that get out of date quickly, especially with plugins
  STDERR.puts "Purging temp files"
  `rm -fr #{Rails.root}/tmp/cache`

  # Ensure we clear emoji cache before pretty-text/emoji/data.js.es6.erb
  # is recompiled
  Emoji.clear_cache

  if !`which uglifyjs`.empty? && !ENV['SKIP_NODE_UGLIFY']
    $node_uglify = true
  end

  unless ENV['USE_SPROCKETS_UGLIFY']
    $bypass_sprockets_uglify = true
    Rails.configuration.assets.js_compressor = nil
    Rails.configuration.assets.gzip = false
  end

  STDERR.puts "Bundling assets"

  # in the past we applied a patch that removed asset postfixes, but it is terrible practice
  # leaving very complicated build issues
  # https://github.com/rails/sprockets-rails/issues/49

  require 'sprockets'
  require 'digest/sha1'

  # Needed for proper source maps with a CDN
  load "#{Rails.root}/lib/global_path.rb"
  include GlobalPath

end

task 'assets:precompile:css' => 'environment' do
  if ENV["DONT_PRECOMPILE_CSS"] == "1"
    STDERR.puts "Skipping CSS precompilation, ensure CSS lives in a shared directory across hosts"
  else
    STDERR.puts "Start compiling CSS: #{Time.zone.now}"

    RailsMultisite::ConnectionManagement.each_connection do |db|
      # Heroku precompiles assets before db migration, so tables may not exist.
      # css will get precompiled during first request instead in that case.

      if ActiveRecord::Base.connection.table_exists?(Theme.table_name)
        STDERR.puts "Compiling css for #{db} #{Time.zone.now}"
        begin
          Stylesheet::Manager.precompile_css
        rescue PG::UndefinedColumn, ActiveModel::MissingAttributeError => e
          STDERR.puts "#{e.class} #{e.message}: #{e.backtrace.join("\n")}"
          STDERR.puts "Skipping precompilation of CSS cause schema is old, you are precompiling prior to running migrations."
        end
      end
    end

    STDERR.puts "Done compiling CSS: #{Time.zone.now}"
  end
end

def assets_path
  "#{Rails.root}/public/assets"
end

def compress_node(from, to)
  to_path = "#{assets_path}/#{to}"
  assets = cdn_relative_path("/assets")
  source_map_root = assets + ((d = File.dirname(from)) == "." ? "" : "/#{d}")
  source_map_url = cdn_path "/assets/#{to}.map"

  cmd = "uglifyjs '#{assets_path}/#{from}' -p relative -m -c -o '#{to_path}' --source-map-root '#{source_map_root}' --source-map '#{assets_path}/#{to}.map' --source-map-url '#{source_map_url}'"

  STDERR.puts cmd
  result = `#{cmd} 2>&1`
  unless $?.success?
    STDERR.puts result
    exit 1
  end

  result
end

def compress_ruby(from, to)
  data = File.read("#{assets_path}/#{from}")

  uglified, map = Uglifier.new(comments: :none,
                               source_map: {
                                 filename: File.basename(from),
                                 output_filename: File.basename(to)
                               }
                              )
    .compile_with_map(data)
  dest = "#{assets_path}/#{to}"

  File.write(dest, uglified << "\n//# sourceMappingURL=#{cdn_path "/assets/#{to}.map"}")
  File.write(dest + ".map", map)

  GC.start
end

def gzip(path)
  STDERR.puts "gzip -f -c -9 #{path} > #{path}.gz"
  STDERR.puts `gzip -f -c -9 #{path} > #{path}.gz`.strip
  raise "gzip compression failed: exit code #{$?.exitstatus}" if $?.exitstatus != 0
end

# different brotli versions use different parameters
def brotli_command(path, max_compress)
  compression_quality = max_compress ? "11" : "6"
  "brotli -f --quality=#{compression_quality} #{path} --output=#{path}.br"
end

def brotli(path, max_compress)
  STDERR.puts brotli_command(path, max_compress)
  STDERR.puts `#{brotli_command(path, max_compress)}`
  raise "brotli compression failed: exit code #{$?.exitstatus}" if $?.exitstatus != 0
  STDERR.puts `chmod +r #{path}.br`.strip
  raise "chmod failed: exit code #{$?.exitstatus}" if $?.exitstatus != 0
end

def max_compress?(path, locales)
  return false if Rails.configuration.assets.skip_minification.include? path
  return true unless path.include? "locales/"

  path_locale = path.delete_prefix("locales/").delete_suffix(".js")
  return true if locales.include? path_locale

  false
end

def compress(from, to)
  if $node_uglify
    compress_node(from, to)
  else
    compress_ruby(from, to)
  end
end

def concurrent?
  executor = Concurrent::FixedThreadPool.new(Concurrent.processor_count)

  if ENV["SPROCKETS_CONCURRENT"] == "1"
    concurrent_compressors = []
    yield(Proc.new { |&block| concurrent_compressors << Concurrent::Future.execute(executor: executor) { block.call } })
    concurrent_compressors.each(&:wait!)
  else
    yield(Proc.new { |&block| block.call })
  end
end

task 'assets:precompile' => 'assets:precompile:before' do
  if refresh_days = SiteSetting.refresh_maxmind_db_during_precompile_days
    mmdb_path = DiscourseIpInfo.mmdb_path('GeoLite2-City')
    mmdb_time = File.exist?(mmdb_path) && File.mtime(mmdb_path)
    if !mmdb_time || mmdb_time < refresh_days.days.ago
      puts "Downloading MaxMindDB..."
      mmdb_thread = Thread.new do
        begin
          DiscourseIpInfo.mmdb_download('GeoLite2-City')
          DiscourseIpInfo.mmdb_download('GeoLite2-ASN')
        rescue => e
          puts "Something when wrong while downloading the MaxMindDB: #{e.message}"
          puts e.backtrace.join("\n")
        end
      end
    end
  end

  if $bypass_sprockets_uglify
    puts "Compressing Javascript and Generating Source Maps"
    startAll = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    manifest = Sprockets::Manifest.new(assets_path)
    locales = Set.new(["en"])

    RailsMultisite::ConnectionManagement.each_connection do |db|
      locales.add(SiteSetting.default_locale)
    end

    concurrent? do |proc|
      manifest.files
        .select { |k, v| k =~ /\.js$/ }
        .each do |file, info|

        path = "#{assets_path}/#{file}"
          _file = (d = File.dirname(file)) == "." ? "_#{file}" : "#{d}/_#{File.basename(file)}"
          _path = "#{assets_path}/#{_file}"
          max_compress = max_compress?(info["logical_path"], locales)
          if File.exists?(_path)
            STDERR.puts "Skipping: #{file} already compressed"
          else
            proc.call do
              start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
              STDERR.puts "#{start} Compressing: #{file}"

              if max_compress
                FileUtils.mv(path, _path)
                compress(_file, file)
              end

              info["size"] = File.size(path)
              info["mtime"] = File.mtime(path).iso8601
              gzip(path)
              brotli(path, max_compress)

              STDERR.puts "Done compressing #{file} : #{(Process.clock_gettime(Process::CLOCK_MONOTONIC) - start).round(2)} secs"
              STDERR.puts
            end
          end
      end
    end

    STDERR.puts "Done compressing all JS files : #{(Process.clock_gettime(Process::CLOCK_MONOTONIC) - startAll).round(2)} secs"
    STDERR.puts

    # protected
    manifest.send :save

    if GlobalSetting.fallback_assets_path.present?
      begin
        FileUtils.cp_r("#{Rails.root}/public/assets/.", GlobalSetting.fallback_assets_path)
      rescue => e
        STDERR.puts "Failed to backup assets to #{GlobalSetting.fallback_assets_path}"
        STDERR.puts e
        STDERR.puts e.backtrace
      end
    end
  end

  mmdb_thread.join if mmdb_thread
end

Rake::Task["assets:precompile"].enhance do
  class Sprockets::Manifest
    def reload
      @filename = find_directory_manifest(@directory)
      @data = json_decode(File.read(@filename))
    end
  end

  # cause on boot we loaded a blank manifest,
  # we need to know where all the assets are to precompile CSS
  # cause CSS uses asset_path
  Rails.application.assets_manifest.reload
  Rake::Task["assets:precompile:css"].invoke
end
