# frozen_string_literal: true

module Docker
  module Compose
    class Port
      attr_accessor :container_port, :host_ip, :host_port

      def initialize(container_port, host_port = nil, host_ip = nil)
        @container_port = container_port
        @host_ip = host_ip
        @host_port = host_port
      end
    end
  end
end