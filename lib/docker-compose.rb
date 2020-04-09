require_relative 'docker-compose/models/compose'
require_relative 'docker-compose/models/compose_container'
require_relative 'version'
require_relative 'docker_compose_config'

require 'yaml'
require 'docker'

module DockerCompose
  #
  # Get Docker client object
  #
  def self.docker_client
    Docker
  end

  #
  # Load a given docker-compose file.
  # Returns a new Compose object
  #
  def self.load(filepath, do_load_running_containers = false)
    unless File.exist?(filepath)
      raise ArgumentError, 'Compose file doesn\'t exists'
    end

    # Parse the docker-compose config
    config = DockerComposeConfig.new(filepath)

    compose = Compose.new

    # Load new containers
    load_containers_from_config(config, compose)

    # Load running containers
    if do_load_running_containers
      load_running_containers(compose)
    end

    # Perform containers linkage
    compose.link_containers

    compose
  end

  def self.load_containers_from_config(config, compose)
    compose_entries = config.services

    if compose_entries
      compose_entries.each do |entry|
        compose.add_container(create_container(entry))
      end
    end
  end

  def self.load_running_containers(compose)
    Docker::Container
      .all(all: true)
      .select {|c| c.info['Labels']['com.docker.compose.project'] == ComposeUtils.dir_name }
      .each do |container|
        compose.add_container(load_running_container(container))
    end
  end

  def self.create_container(attributes)
    ComposeContainer.new({
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

    container_args = {
      label:        info['Name'].gsub('/', ''),
      full_name:    info['Name'],
      image:        info['Image'],
      build:        nil,
      links:        info['HostConfig']['Links'],
      cap_add:      info['HostConfig']['CapAdd'],
      security_opt: info['HostConfig']['SecurityOpt'],
      shm_size:     info['HostConfig']['ShmSize'],
      ports:        ComposeUtils.format_ports_from_running_container(info['NetworkSettings']['Ports']),
      volumes:      info['Config']['Volumes'],
      command:      ComposeUtils.format_command_from_running_container(info['Config']['Cmd']),
      environment:  info['Config']['Env'],
      labels:       info['Config']['Labels'],

      loaded_from_environment: true
    }
    ComposeContainer.new(container_args, container)
  end

  private_class_method :load_containers_from_config,
                       :create_container,
                       :load_running_containers,
                       :load_running_container
end
