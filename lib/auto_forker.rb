require 'socket'
require 'tempfile'

# @example
#   require 'auto_forker'
#   AutoForker.new(12345, data: [1, 2, 3]).start do |socket, data|
#     socket.gets
#     socket.puts [$$, data.shift].inspect
#     socket.close if data.empty?
#   end
#
#   % ruby example.rb &
#   % telnet 127.0.0.1 12345
#   Trying 127.0.0.1...
#   Connected to 127.0.0.1.
#   Escape character is '^]'.
#   (type Enter)
#   [3101, 1]
#   (type Enter)
#   [3101, 2]
#   (wait 3 sec. & type Enter)
#   [3104, 3]
#   Connection closed by foreign host.
class AutoForker
  # @param port [Integer, String] TCP server port
  # @param opts [Hash] options
  # @option opts [Proc] :on_connect called when connect with socket, data
  # @option opts [Proc] :on_disconnect called when disconnect with socket, data
  # @option opts [Proc] :on_readable called when be readable with socket, data
  # @option opts [Numeric] :read_timeout time to wait for input before the process exit (default: 3)
  # @option opts [Object] :data user data
  def initialize(port, opts={})
    @port = port
    @opts = opts
    @clients = []
    @child_pids = []
  end

  # Main loop.
  # a block or :on_readable are required.
  # If block is specified, on_readable is overwriten.
  # @yield [socket, data]
  # @yieldparam socket [Socket]
  # @yieldparam data [Object]
  def start(&block)
    @on_readable = block if block
    raise 'block required' unless @on_readable
    @server_sockets = Socket.tcp_server_sockets(@port).map{|s| [s, true]}.to_h
    @watching = @server_sockets.keys
    while true
      readable, = IO.select(@watching)
      readable.each do |r|
        case
        when @server_sockets[r]
          connected r
        when @clients.any?{|c| c.socket == r }
          readable r
        when @clients.any?{|c| c.child_socket == r }
          child_died r
        else
          raise "invalid io: #{r.inspect}"
        end
      end
      wait_children
    end
  end

  # called when new connection
  # @param server_socket [Socket]
  def connected(server_socket)
    begin
      socket, addr = server_socket.accept_nonblock
    rescue IO::WaitReadable
      return
    end
    client = Client.new(socket: socket, data_file: Tempfile.new('auto_forker'))
    @clients.push client
    child(client) do
      data = @opts[:data]
      @opts[:on_connect].call(client.socket, addr, data) if @opts[:on_connect]
      run(client, data)
    end
  end

  # called when socket is readable
  # @param socket [Socket]
  def readable(socket)
    client = @clients.find{|c| c.socket == socket }
    child(client) do
      run(client, client.load_data)
    end
    @watching.delete socket
  end

  # @private
  # @param client [AutoForker::Client]
  def child(client)
    ps, cs = UNIXSocket.pair
    pid = fork
    unless pid # child
      @server_sockets.keys.each(&:close)
      @clients.each do |c|
        c.socket.close unless c.socket == client.socket
        c.child_socket.close if c.child_socket
      end
      client.parent_socket = ps
      cs.close
      yield
      exit!
    end
    ps.close
    client.child_socket = cs
    client.socket.close
    @child_pids.push pid
    @watching.push cs
  end

  # @private
  # @param peer [UNIXSocket]
  def child_died(peer)
    client = @clients.find{|c| c.child_socket == peer }
    client.child_socket = nil
    @watching.delete peer
    socket = peer.recv_io rescue nil
    peer.close
    if socket
      @watching.push socket
      socket.sync = true
      client.socket = socket
    else
      client.remove_data
      @clients.delete_if{|c| c.child_socket == peer }
    end
  end

  # @private
  def wait_children
    @child_pids.delete_if do |pid|
      Process.waitpid(pid, Process::WNOHANG)
    end
  end

  # @private
  # run in child process
  # @param client [AutoForker::Client]
  # @param data [Object]
  def run(client, data)
    while IO.select([client.socket], nil, nil, @opts[:read_timeout] || 3)
      if client.socket.eof?
        @opts[:on_disconnect].call(client.socket, data) if @opts[:on_disconnect]
        return
      end
      @on_readable.call(client.socket, data)
      return if client.socket.closed?
    end
    client.save_data(data)
    client.parent_socket.send_io client.socket
  rescue Errno::ECONNRESET
    @opts[:on_disconnect].call(client.socket, data) if @opts[:on_disconnect]
  end

  class Client
    attr_accessor :data_file, :socket, :child_socket, :parent_socket

    # @param opts [Hash]
    def initialize(opts={})
      @data_file, @socket, @child_socket, @parent_socket = opts.values_at(:data_file, :socket, :child_socket, :parent_socket)
    end

    # load data from file
    def load_data
      Marshal.load(File.read(data_file))
    rescue Errno::ENOENT
      nil
    end

    # save data to file
    # @param data [Object]
    def save_data(data)
      File.write(data_file, Marshal.dump(data))
    end

    # remove data file
    def remove_data
      File.unlink data_file
    rescue Errno::ENOENT
      nil
    end
  end
end
