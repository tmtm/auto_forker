# AutoForker

## Installation

Add this line to your application's Gemfile:

```ruby
gem 'auto_forker'
```

And then execute:

    $ bundle

Or install it yourself as:

    $ gem install auto_forker

## Usage

```ruby
require 'auto_forker'
AutoForker.new(12345, data: [1, 2, 3]).start do |socket, data|
  socket.gets
  socket.puts [$$, data.shift].inspect
  socket.close if data.empty?
end
```

```
% ruby example.rb &
% telnet 127.0.0.1 12345
Trying 127.0.0.1...
Connected to 127.0.0.1.
Escape character is '^]'.
(type Enter)
[3101, 1]
(type Enter)
[3101, 2]
(wait 3 sec. & type Enter)
[3104, 3]
Connection closed by foreign host.
```

## Contributing

Bug reports and pull requests are welcome on GitHub at https://github.com/tmtm/auto_forker.
