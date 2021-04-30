# frozen_string_literal: true

require 'docker'
require 'securerandom'
require_relative 'port'
require_relative '../utils/compose_utils'

module Docker
  module Compose
    # @attr composed_attributes [Hash]
    # @attr internal_image [Docker::Image]
    # @attr docker_container [Docker::Container]
    # @attr dependencies [Docker::Container]
    class Container
      attr_accessor :attributes, :internal_image, :docker_container, :dependencies

      def initialize(attributes, docker_container = nil)
        container_name = attributes[:full_name]
        container_name ||=
          [
            Docker::Compose::Utils.dir_name,
            attributes[:name] || attributes[:label],
            Docker::Compose::Utils.next_available_id,
          ].join('_')
        # gives: "[compose_directory]_[container name]_[id]"

        image_name = attributes[:image]&.include?(':') ? attributes[:image] : "#{attributes[:image]}:latest"
          # expects: "[image]:[tag]" | "[image]"
        service_links = attributes[:links]&.map {|x| (service,label) = x.split(':'); [service, (label || service)] }.to_h
          # expects: "[service]:[label]" | "[service]"
        ports = attributes[:ports].map { |port_string| Port.new(port_entry.to_s.split(':').reverse) }
          # expects: "[host ip]:[host port]:[container port]" | "[host port]:[container port]" | "[container port]"

        @attributes =
          {
            service: attributes[:service],
            label: attributes[:label],
            loaded_from_environment: attributes[:loaded_from_environment],
            name:  container_name,
            image: image_name,
            build: attributes[:build],
            links: service_links,
            ports: ports,
            volumes: attributes[:volumes],
            shm_size: attributes[:shm_size],
            entrypoint: attributes[:entrypoint],
            command: attributes[:command]&.split(' '),
            environment: prepare_environment(attributes[:environment]),
            labels: prepare_labels(attributes[:labels]),
            cap_add: attributes[:cap_add],
            security_opt: attributes[:security_opt],
          }.compact

        @attributes[:labels] = {} unless @attributes[:labels].is_a?(Hash)
        @attributes[:labels].merge!(
          {
            'com.docker.compose.project' => ComposeUtils.dir_name,
            'com.docker.compose.service' => @attributes[:service],
            'com.docker.compose.oneoff' => 'False',
          }
        )

        # Docker client variables
        @internal_image = nil
        @docker_container = docker_container
        @dependencies = []
      end

      #
      # Returns true if is a container loaded from
      # environment instead compose file (i.e. a running container)
      #
      def loaded_from_environment?
        attributes[:loaded_from_environment]
      end

      private

      #
      # Download or build an image
      #
      def prepare_image
        has_image_or_build_arg = @attributes.key?(:image) || @attributes.key?(:build)

        raise ArgumentError.new('No Image or Build command provided') unless has_image_or_build_arg

        # Build or pull image
        if @attributes.key?(:image)
          @internal_image = @attributes[:image]

          unless image_exists(@internal_image)
            Docker::Image.create('fromImage' => @internal_image)
          end
        elsif @attributes.key?(:build)
          @internal_image = SecureRandom.hex # Random name for image
          opts = {t: @internal_image}

          # docker-api can't figure out context directive
          # We need to convert it to path instead
          if @attributes[:build].is_a? Hash
            dir = @attributes[:build]['context']

            # Use all other opts as is but remove context
            opts.merge!(@attributes[:build]).delete('context')
          end

          dir ||= @attributes[:build]

          Docker::Image.build_from_dir(dir, opts)
        end
      end

      #
      # Start a new container with parameters informed in object construction
      #
      def prepare_container
        # Prepare attributes
        port_bindings = prepare_port_bindings
        links = prepare_links
        volumes = prepare_volumes
        volume_binds = prepare_volume_binds

        # Exposed ports are port bindings with an empty hash as value
        exposed_ports = {}
        port_bindings.each {|k, v| exposed_ports[k] = {}}

        container_config = {
          Image: @internal_image,
          Cmd: @attributes[:command],
          Env: @attributes[:environment],
          Volumes: volumes,
          ExposedPorts: exposed_ports,
          Labels: @attributes[:labels],
          HostConfig: {
            Binds: volume_binds,
            Links: links,
            PortBindings: port_bindings,
            CapAdd: @attributes[:cap_add],
            SecurityOpt: @attributes[:security_opt],
            ShmSize: prepare_shm_size
          }
        }

        query_params = { 'name' => @attributes[:name] }

        params = container_config.merge(query_params)
        @docker_container = Docker::Container.create(params)
      end

      #
      # Prepare port binding attribute based on ports
      # received from compose file
      #
      def prepare_port_bindings
        port_bindings = {}

        return port_bindings if @attributes[:ports].nil?

        @attributes[:ports].each do |port|
          port_bindings["#{port.container_port}/tcp"] = [{
            "HostIp" => port.host_ip || '',
            "HostPort" => port.host_port || ''
          }]
        end

        port_bindings
      end

      #
      # Prepare shared memory size.
      # Use specified or set default 64M
      #
      def prepare_shm_size
        # set default 64M if nothing specified
        return 67108864 unless @attributes[:shm_size]

        value, units = @attributes[:shm_size].match(/(\d+)(\w+)?/)[1, 2]
        case units.to_s.downcase
        when 'g', 'gb' then value.to_i * 1073741824
        when 'm', 'mb' then value.to_i * 1048576
        when 'k', 'kb' then value.to_i * 1024
        else value.to_i
        end
      end

      #
      # Prepare link entries based on
      # attributes received from compose
      #
      def prepare_links
        links = []

        @dependencies.each do |dependency|
          link_name = @attributes[:links][dependency.attributes[:service]]
          links << "#{dependency.stats['Id']}:#{link_name}"
        end

        links
      end

      #
      # Transforms an array of [(host:)container(:accessmode)] to a hash
      # required by the Docker api.
      #
      def prepare_volumes
        return unless @attributes[:volumes]

        volumes = {}

        @attributes[:volumes].each do |volume|
          # support relative paths
          volume.sub!('./', Dir.pwd + '/')
          parts = volume.split(':')

          if parts.one?
            volumes[parts[0]] = {}
          else
            volumes[parts[1]] = { parts[0] => parts[2] || 'rw' }
          end
        end

        volumes
      end

      #
      # Prepare Hostconfig Bind mounts by converting
      # relative paths into absolute paths
      #
      def prepare_volume_binds
        return if @attributes[:volumes].nil?

        binds = @attributes[:volumes].reject { |volume| volume.split(':').one? }

        # Convert relative paths to absolute paths
        binds.map do |bind|
          bind.split(':').map do |path|
            if ! path.start_with? '/' and ! ['rw','ro'].include? path
              File.expand_path(path)
            else
              path
            end
          end.join(':')
        end
      end

      #
      # Forces the environment structure to use the array format.
      #
      def prepare_environment(env_entries)
        return env_entries unless env_entries.is_a?(Hash)
        env_entries.to_a.map { |x| x.join('=') }
      end

      #
      # Forces the labels structure to use the hash format.
      #
      def prepare_labels(labels)
        return labels unless labels.is_a?(Array)
        Hash[labels.map { |label| label.split('=') }]
      end

      #
      # Check if a given image already exists in host
      #
      def image_exists(image_name)
        Docker::Image.exist?(image_name)
      end

      public

      #
      # Start the container and its dependencies
      #
      def start
        # Start dependencies
        @dependencies.each do |dependency|
          dependency.start unless dependency.running?
        end

        # Create a container object
        if @docker_container.nil?
          prepare_image
          prepare_container
        end

        @docker_container.start unless @docker_container.nil?
      end

      #
      # Stop the container
      #
      def stop
        @docker_container.stop unless @docker_container.nil?
      end

      #
      # Kill the container
      #
      def kill
        @docker_container.kill unless @docker_container.nil?
      end

      #
      # Delete the container
      #
      def delete
        @docker_container.delete(:force => true) unless @docker_container.nil?
        @docker_container = nil
      end

      #
      # Add a dependency to this container
      # (i.e. a container that must be started before this one)
      #
      def add_dependency(dependency)
        @dependencies << dependency
      end

      #
      # Return container statistics
      #
      def stats
        @docker_container.json
      end

      #
      # Check if a container is already running or not
      #
      def running?
        @docker_container.nil? ? false : self.stats['State']['Running']
      end

      #
      # Check if the container exists or not
      #
      def exist?
        !@docker_container.nil?
      end
    end
  end
end
