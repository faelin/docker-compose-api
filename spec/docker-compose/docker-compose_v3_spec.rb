require 'spec_helper'

describe DockerCompose do
  context 'version 3' do
    before(:each) {
      @compose = DockerCompose.load(File.expand_path('spec/docker-compose/fixtures/compose_3.yaml'))
    }

    after(:each) do
      @compose.delete
    end

    it 'should be able to access gem version' do
      expect(DockerCompose.version).to_not be_nil
    end

    it 'should be able to access Docker client' do
      expect(DockerCompose.docker_client).to_not be_nil
    end

    it 'should read 3 containers' do
      expect(@compose.containers.length).to eq(3)
    end

    it 'uses cap_add correctly' do
      container = @compose.get_containers_by(label: 'busybox').first

      # Start container
      container.start

      caps_added = container.stats['HostConfig']['CapAdd']
      expect(caps_added).to match_array(['SYS_ADMIN'])

      # Stop container
      container.stop
    end

    it 'uses security_opt correctly' do
      container = @compose.get_containers_by(label: 'busybox').first

      # Start container
      container.start

      security_opts = container.stats['HostConfig']['SecurityOpt']
      expect(security_opts).to match_array(['apparmor:unconfined'])

      # Stop container
      container.stop
    end
  end
end
