
# Set up a forwarding

# Server proxy --
# Protocol
# Client creates command socket by connecting to server. When server wants to send
# data, server send request to client with new port to connect to. The client then creates a
# outgoing connection to the server and begins to receive data forwarding it to the
# local destination. Results are then proxied back to the originator.

require 'socket'
require 'proxy'
require 'thread'
require 'timeout'

if ARGV.length < 1
  puts "Usage: proxy_server <port>"
  exit 999
end

STDOUT.sync = true

class CommandSocket
  attr_reader :port
  
  @@socket_queue = Queue.new
  
  def initialize(command, server, port)
    @command = command
    @proxies = Hash.new
    @available_proxies = Array.new
    @active = true
    @index = 0
    @port = port
    @server = server
  end
  
  def create_proxy(port)
    @port = port
    @proxy = TCPServer.new('127.0.0.1', port)
    true
  rescue
    puts $!
    puts "Cannot create server port"
    false
  end

  def send_client_connect(index)
    puts "Asking client to connect to #{index}"
    unless @command.write("C%06d\n" % index)
      shutdown
      raise "Write failed, shutting down"
    end
  end

  def accept
    client = @proxy.accept

    if proxy = @available_proxies.pop
      proxy.reset_dest(client)
      send_client_connect(proxy.index)
    else
      @index += 1

      source = nil
      Timeout::timeout(20) do
        send_client_connect(@index)
        source = @@socket_queue.pop
      end
      @proxies[@index] = Proxy.new(source, client, self, @index)
    end


  rescue IOError
    puts "Server socket closed for #{@port}"

  rescue
    puts $!, $!.class
    puts $!.backtrace.join("\n")
    shutdown
  end

  def add_socket(sock)
    @@socket_queue << sock
  end

  def shutdown_remote(proxy)
    if @active
      puts "Proxy #{proxy.index} shut down dest socket"
      @command.write("S%06d\n" % proxy.index)
      @available_proxies << proxy
    end
  end

  def run
    @cmd_thread = Thread.new do
      begin
        while @active
          cmd = @command.read(8)
          puts "Received command '#{cmd}'"
          if cmd.nil? or cmd.length == 0
            shutdown
            break
          end
          
          if cmd =~ /[CS]\d+\n/
            puts "Received command #{cmd}"
            oper, ind = cmd[0], cmd[1..-1].to_i
            
            if oper == ?S
              proxy = @proxies[ind]
              # proxy.shutdown_dest if proxy
            end
          end
          
        end
      rescue
      end
      
      shutdown
      puts "Exiting command thread for #{@port}"
    end
    
    @accept = Thread.new do
      while @active
        accept
      end

      puts "Exiting accept thread"
    end
  end

  def shutdown
    return unless @active
    
    @active = false

    puts "In shutdown..."
    @server.remove_client(self)
    
    puts "Shutting down #{@command.addr.inspect} for port #{@port}"
    @command.shutdown rescue puts "Command: #{$!}"
    @proxy.close rescue puts "Proxy: #{$!}"
    @proxies.values.each { |p| p.shutdown }

    @accept.kill unless Thread.current == @accept
    @cmd_thread.kill unless Thread.current == @cmd_thread

    puts "#{@port} is now shutdown"
  rescue
    puts $!, $!.class
    puts $!.backtrace.join("\n")
  end
end

class Server
  def initialize(port)
    @port = port
    @server = TCPServer.new(port)
    @server.listen(10)
    @clients = Hash.new
  end
  
  def accept
    while true
      puts "Waiting on #{@port}"
      s = @server.accept
      cmd = s.read(8)
      puts "Received command #{cmd}"
      if cmd !~ /[CP]\d{6}\n/
          puts "bad connection request: #{port.inspect}"
      else
        oper, port = cmd[0], cmd[1..-1].to_i
        if oper == ?C
          if port.nil? or port.to_i < 1025
            puts "Received bad port: #{port}"
            next
          end

          puts "Creating proxy server on port #{port.to_i}"
          client = CommandSocket.new(s, self, port)
          if client.create_proxy(port.to_i)
            @clients[port] = client
            client.run
          else
            puts "Could not create proxy server"
            s.write("F0000001\n")
            s.shutdown
          end
        elsif oper == ?P
          client = @clients[port]
          if client
            client.add_socket(s)
          else
            puts "Could not find client for #{port}"
          end
        end
      end
    end
  end

  def remove_client(client)
    puts "Removing client #{client.port}"
    @clients.delete(client.port)
  end
end

server = Server.new(ARGV[0].to_i)
server.accept


