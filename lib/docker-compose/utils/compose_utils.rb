module Docker
  module Compose
    module Utils
      # Returns the directory name where the compose file is saved
      #
      # @return [String]
      def dir_name
        @dir_name ||= File.split(Dir.pwd).last.gsub(/[_]/)
      end

      # Provides the next available container ID
      #
      # @return [Integer]
      def next_available_id
        @current_container_id ||= Docker::Container.all(opts: { all: true }).map {|c| c.info['Names'].last.split(/_/).last.to_i}.flatten.max || 0
        @current_container_id += 1
      end
    end
  end
end
