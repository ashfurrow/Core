require 'cocoapods-core/source'
require 'rest'
require 'concurrent'

module Pod
  # Subclass of Pod::Source to provide support for CDN-based Specs repositories
  #
  class CDNSource < Source
    # @param [String] repo The name of the repository
    #
    def initialize(repo)
      # Optimization: we initialize startup_time when the source is first initialized
      # and then test file modification dates against it. Any file that was touched
      # after the source was initialized, is considered fresh enough.
      @startup_time = Time.new

      @executor = Concurrent::ThreadPoolExecutor.new(
        :min_threads => 1,
        :max_threads => 200,
        :max_queue => 0 # unbounded work queue
      )
      super(repo)
    end

    # @return [String] The URL of the source.
    #
    def url
      @url ||= File.read(repo.join('.url'))
    end

    # @return [String] The type of the source.
    #
    def type
      'CDN'
    end

    def refresh_metadata
      if metadata.nil?
        unless repo.exist?
          raise Informative, "Unable to find a source named: `#{name}`"
        end

        specs_dir.mkpath
        download_file('CocoaPods-version.yml')

        preheat_existing_files
      end

      super
    end

    def preheat_existing_files
      # Optimization: all the version index files in the local cache will in all probability be
      # requested anyaway, better preload them in parallel.
      glob_pattern = repo.join('*/**/*.txt')
      loaders = Pathname.glob(glob_pattern).map { |f| f.relative_path_from(repo) }.map do |file|
        Concurrent::Promise.execute(:executor => @executor) do
          download_file(file)
        end
      end
      Concurrent::Promise.zip(*loaders).wait!
    end

    # @return [Pathname] The directory where the specs are stored.
    #
    def specs_dir
      @specs_dir ||= repo + 'Specs'
    end

    # @!group Querying the source
    #-------------------------------------------------------------------------#

    # @return [Array<String>] the list of the name of all the Pods.
    #
    def pods
      download_file('all_pods.txt')
      local_file('all_pods.txt', &:to_a).map(&:chomp)
    end

    # @return [Array<Version>] all the available versions for the Pod, sorted
    #         from highest to lowest.
    #
    # @param  [String] name
    #         the name of the Pod.
    #
    def versions(name)
      return nil unless specs_dir
      raise ArgumentError, 'No name' unless name

      return @versions_by_name[name] unless @versions_by_name[name].nil?

      pod_path_actual = pod_path(name)
      pod_path_relative = relative_pod_path(name)
      versions_file_path_relative = pod_path_relative.join(INDEX_FILE_NAME)
      download_file(versions_file_path_relative)

      return nil unless pod_path_actual.join(INDEX_FILE_NAME).exist?

      loaders = []
      @versions_by_name[name] ||= local_file(versions_file_path_relative) do |file|
        file.map do |v|
          version = v.chomp

          # Optimization: ensure all the podspec files at least exist. The correct one will get refreshed
          # in #specification_path regardless.
          podspec_version_path_relative = Pathname.new(version).join("#{name}.podspec.json")
          unless pod_path_actual.join(podspec_version_path_relative).exist?
            loaders << Concurrent::Promise.execute(:executor => @executor) do
              download_file(pod_path_relative.join(podspec_version_path_relative))
            end
          end
          begin
            Version.new(version) if version[0, 1] != '.'
          rescue ArgumentError
            raise Informative, 'An unexpected version directory ' \
            "`#{version}` was encountered for the " \
            "`#{pod_dir}` Pod in the `#{name}` repository."
          end
        end
      end.compact.sort.reverse
      Concurrent::Promise.zip(*loaders).wait!
      @versions_by_name[name]
    end

    # Returns the path of the specification with the given name and version.
    #
    # @param  [String] name
    #         the name of the Pod.
    #
    # @param  [Version,String] version
    #         the version for the specification.
    #
    # @return [Pathname] The path of the specification.
    #
    def specification_path(name, version)
      raise ArgumentError, 'No name' unless name
      raise ArgumentError, 'No version' unless version

      podspec_version_path_relative = Pathname.new(version.to_s).join("#{name}.podspec.json")
      relative_podspec = relative_pod_path(name).join(podspec_version_path_relative)
      download_file(relative_podspec)
      pod_path(name).join(podspec_version_path_relative)
    end

    # @return [Array<Specification>] all the specifications contained by the
    #         source.
    #
    def all_specs
      raise Informative, "Can't retrieve all the specs for a CDN-backed source, it will take forever"
    end

    # @!group Searching the source
    #-------------------------------------------------------------------------#

    # @return [Set] a set for a given dependency. The set is identified by the
    #               name of the dependency and takes into account subspecs.
    #
    # @note   This method is optimized for fast lookups by name, i.e. it does
    #         *not* require iterating through {#pod_sets}
    #
    # @todo   Rename to #load_set
    #
    def search(query)
      unless specs_dir
        raise Informative, "Unable to find a source named: `#{name}`"
      end
      if query.is_a?(Dependency)
        query = query.root_name
      end

      found = download_file(relative_pod_path(query).join(INDEX_FILE_NAME))

      if found
        set = set(query)
        set if set.specification_name == query
      end
    end

    # @return [Array<Set>] The list of the sets that contain the search term.
    #
    # @param  [String] query
    #         the search term. Can be a regular expression.
    #
    # @param  [Bool] full_text_search
    #         not supported due to performance reasons
    #
    # @note   full text search requires to load the specification for each pod,
    #         and therefore not supported.
    #
    def search_by_name(query, full_text_search = false)
      if full_text_search
        raise Informative, "Can't perform full text search, it will take forever"
      else
        super(query)
      end
    end

    # Does nothing, since CDN-backed repo is updated live.
    #
    # @param  [Bool] show_output
    #
    # @return  [Array<String>] changed_spec_paths
    #          Returns the list of changed spec paths.
    #
    def update(_show_output)
      debug 'No need to update CDN-backed repo'
      []
    end

    def git?
      false
    end

    private

    # Index files contain all the sub directories in the directory, separated by
    # a newline. We use those because you can't get a directory listing from a CDN.
    INDEX_FILE_NAME = 'index.txt'.freeze

    def local_file(partial_url)
      File.open(repo.join(partial_url)) do |file|
        yield file if block_given?
      end
    end

    def relative_pod_path(pod_name)
      pod_path(pod_name).relative_path_from(repo)
    end

    def download_file(partial_url)
      file_remote_url = url + partial_url.to_s
      path = repo + partial_url

      if File.exist?(path) && @startup_time < File.mtime(path)
        debug "CDN: #{name} Relative path: #{partial_url} modified during this run! Returning local"
        return partial_url
      end

      path.dirname.mkpath

      etag_path = path.sub_ext(path.extname + '.etag')

      etag = File.read(etag_path) if File.exist?(etag_path)
      debug "CDN: #{name} Relative path: #{partial_url}, has ETag? #{etag}" unless etag.nil?

      response = etag.nil? ? REST.get(file_remote_url) : REST.get(file_remote_url, 'If-None-Match' => etag)

      case response.status_code
      when 304
        debug "CDN: #{name} Relative path not modified: #{partial_url}"
        # We need to update the file modification date, as it is later used for freshness
        # optimization. See #initialize for more information.
        FileUtils.touch path
        partial_url
      when 200
        File.open(path, 'w') { |f| f.write(response.body) }

        etag_new = response.headers['etag'].first if response.headers.include?('etag')
        debug "CDN: #{name} Relative path downloaded: #{partial_url}, save ETag: #{etag_new}"
        File.open(etag_path, 'w') { |f| f.write(etag_new) } unless etag_new.nil?
        partial_url
      end
    end

    def debug(message)
      if defined?(Pod::UI)
        Pod::UI.message(message)
      else
        CoreUI.puts(message)
      end
    end
  end
end
