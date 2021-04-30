require_relative 'docker-compose/models/base'
require_relative 'docker-compose/models/container'
require_relative 'version'
require_relative 'docker_compose_config'

require 'yaml'
require 'docker'
# require_relative 'docker_compose/port'
# require_relative 'utils/compose_utils'

module Docker
  class DockerError < StandardError
    class DockerComposeError < DockerError; end
  end

  class Compose
    class DuplicateContainerError < DockerComposeError; end
    class ParseError < DockerComposeError; end

    class << self
      # @attr containers [Hash]
      attr_accessor :containers

      # Get Docker client object
      def connector
        Docker
      end

      # Load a given docker-compose file.
      #
      # @param filepath [String] path to a docker-compose yaml file.
      # @param load_running [true, false] a flag to force loading of services that are already running.
      # @param options [Hash] there are currently no options defined for Docker::Compose.new
      # @return [DockerCompose::Base]
      def load(filepath, load_running, **options)
        @containers = {}

        raise ArgumentError, "docker-compose file not found: #{filepath}" unless File.exist?(filepath)

        config = Docker::Compose::Config.new(filepath)
        load_containers_from_config(config)
        load_running_containers if load_running
        link_containers
      end

      # @param container [Container]
      # @return [true, false]
      def add_container(container)
        raise DuplicateContainerError, "a container always exists with label '#{container.attributes[:label]}'!" if @containers.key? container.attributes[:label]

        @containers[container.attributes[:label]] = container
        true
      end

      # @param config [Docker::Compose::Config]
      # @return [Class<Docker::Compose>]
      def load_containers_from_config(config)
        config.services.each { |entry| self.add_container(create_container(entry)) }
        self
      end

      # @return [Class<Docker::Compose>]
      def load_running_containers
        Docker::Container
          .all(all: true)
          .select {|c| c.info['Labels']['com.docker.compose.project'] == ComposeUtils.dir_name }
          .each { |container| self.add_container(container) }
        self
      end

      # Select containers based on a selection of attributes.
      #
      # @param params [Hash] hash of attributes to query by
      # @return [Array<Docker::Compose::Container>]
      def get_containers_by(**params)
        @containers.select do |_label, container|
          params.all? { |key,val| container.attributes[key] == val }
        end
      end

      # Select containers based on its given name
      #   (ignore basename)
      #
      # @param name [String]
      # @return [Array<Docker::Compose::Container>]
      def get_containers_by_name(name)
        @containers.select { |_label, container|
          container.attributes[:name].match(/#{ComposeUtils.dir_name}_#{name}_\d+/)
        }
      end

      # Create link relations among containers
      # @return [Class<Docker::Compose>]
      def link_containers
        @containers.each_value do |container|
          next if container.loaded_from_environment?

          links = container.attributes[:links]
          next if links.nil?

          links.each do |service, _name|
            dependency_container = @containers.values.find { |c| c.attributes[:service] == service }
            container.add_dependency(dependency_container)
          end
        end

        self
      end

      def self.create_container(attributes)
        Container.new({
          service: attributes[0],
          label: attributes[1]['container_name'],
          full_name: attributes[1]['container_name'],
          image: attributes[1]['image'],
          build: attributes[1]['build'],
          links: attributes[1]['links'],
          ports: attributes[1]['ports'],
          volumes: attributes[1]['volumes'],
          shm_size: attributes[1]['shm_size'],
          command: attributes[1]['command'],
          entrypoint: attributes[1]['entrypoint'],
          environment: attributes[1]['environment'],
          labels: attributes[1]['labels'],
          security_opt: attributes[1]['security_opt'],
          cap_add: attributes[1]['cap_add'],
        })
      end

      def self.load_running_container(container)
        info = container.json

        port_entries = info['NetworkSettings']['Ports'].map do |key, val|
          container_port = key.gsub(/\D/).to_i

          # Ports that are EXPOSEd but not published won't have a Host IP/Port, only a Container Port.
          host_port = val.dig(0,'HostPort')
          host_ip = val.dig(0,'HostIp')

          raise Docker::Compose::ParseError, "cannot specify a host IP address without a post port" if host_port.blank? and host_ip.present?

          [ container_port, host_ip, host_port ].join(':')
        end

        container_args = {
          label:        info['Name'].gsub('/', ''),
          full_name:    info['Name'],
          image:        info['Image'],
          build:        nil,
          links:        info['HostConfig']['Links'],
          cap_add:      info['HostConfig']['CapAdd'],
          security_opt: info['HostConfig']['SecurityOpt'],
          shm_size:     info['HostConfig']['ShmSize'],
          ports:        port_entries,
          volumes:      info['Config']['Volumes'],
          command:      info['Config']['Cmd']&.join(' '),
          environment:  info['Config']['Env'],
          labels:       info['Config']['Labels'],

          loaded_from_environment: true
        }
        Container.new(container_args, container)
      end

      # @param containers [Array] the list of container names to start.
      def up(*containers)
        containers.each do |container_name|
          p "Starting container '#{container_name}'..."
          target = Helper.client.get_containers_by(name: container_name).first
          raise ArgumentError, "container not found: '#{container_name}'" if target.nil?

          target.start unless target.running?
        end
        p 'done!' if containers.any?
      end

      # @param containers [Array] the list of container names to stop.
      def down(*containers)
        containers.each do |container_name|
          p "Stopping container '#{container_name}'..."
          target = Helper.client.get_containers_by(name: container_name).first
          target.stop if target.running?
        end
        p 'done!' if containers.any?
      end

      # Start a container
      #
      # This method accepts an array of labels.
      # If labels is informed, only those containers with label present in array will be started.
      # Otherwise, all containers are started
      #
      def start(labels = [])
        call_container_method(:start, labels)
      end

      #
      # Stop a container
      #
      # This method accepts an array of labels.
      # If labels is informed, only those containers with label present in array will be stopped.
      # Otherwise, all containers are stopped
      #
      def stop(labels = [])
        call_container_method(:stop, labels)
      end

      # Kill the named containers.
      #
      # This method accepts an array of labels.
      # If labels is informed, only those containers with label present in array will be killed.
      # Otherwise, all containers are killed
      #
      # @param labels [Array<String>] the labels of the containers to be stopped
      def kill(labels = [])
        call_container_method(:kill, labels)
      end

      #
      # Delete a container
      #
      # This method accepts an array of labels.
      # If labels is informed, only those containers with label present in array will be deleted.
      # Otherwise, all containers are deleted
      #
      # @param labels [Array<String>] the labels of the containers to be removed
      def delete(labels = [])
        call_container_method(:delete, labels)
        delete_containers_entries(labels)
      end

    private

      def call_container_method(method, labels = [])
        labels = @containers.keys if labels.empty?
        @containers.slice(*labels).each_value(&:method)
        self
      end

      def delete_containers_entries(labels = [])
        labels = @containers.keys if labels.empty?
        labels.each { |label| @containers.delete(label) }
        self
      end
    end
  end
end
