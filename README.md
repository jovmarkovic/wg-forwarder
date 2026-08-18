# wg-forwarder
WireGuard helper for seamless endpoint host switching 

---

## WIP
Change configuration file to yaml at some point (implement yaml parsing).

Copy default config template and service file on installation step. 

---
## Usage/Flags
```
-c <config_path>
```
---

## Configuration
Currently supports json formatting.  

Example:
```
{
  "log_level": "info",
  "client_endpoint": {
    "address": "127.0.0.1",
    "port": 51821
  },
  "forwarder_socket": {
    "address": "127.0.0.1",
    "port": 61821
  },
  "server_socket": {
    "address": "0.0.0.0",
    "port": 8921
  },
  "switcher": {
    "enabled": false,
    "id": 0,
    "timer": 19,
    "endpoints": [
      "192.168.1.4:8921",
      "100.116.14.17:8921"
    ]
  }
  "admin_console": {
    "enabled": false,
    "address": 127.0.0.1,
    "port": 9000,
  }
}

```
- when switcher enabled is set to false, it would skip starting the switcher thread and ignore auto switching endpoints.
- server_socket structure can be omitted. Defaults for it are: address: "0.0.0.0", port: 0
- timer can be omitted if the switcher is set to false. Otherwise it would panic 
- log_level can be omitted, it will use Zig's default log level in that case.
- id is used to set an initial server endpoint. 
- admin_console structure can be omitted, Defaults for it are: enabled: false, address: "127.0.0.1", port: "9000"

## Explanation
- log_level: Runtime logging level of the service.
- client_endpoint: Endpoint of the wireguard client that wants to send packets to a server.
- forwarder_socket: Socket that accepts packets from client_endpoint. 

  In WireGuard client configuration you need to specify this as a peer endpoint for a server
- server_socket: Socket that accepts from and sends packets to server. 
  
  When not set, kernel will decide which port to use and listen on all addresses.

- switcher: function that does seamless endpoint switching. 

  If set to false, use ID to set the index of your desired server endpoint.

- admin_console: function that opens up server endpoint for chagning forwarder's runtime state. 


## Configuration types
- log_level: err, warn, info, debug

- address: IPv4

- port: u16

- timer: (u32) seconds 

- id: u32

- enabled: bool

- endpoints: [ "IPv4:port", "IPv4:port", ... ,"IPv4:port" ]


## Admin server options
Admin server has three states, global, endpoint and switcher.
Connecting to it via `telnet` or `nc` for example, will set a global state.

Currently supported commands in states:
```
Available Global Commands:
  help (?)        - Show this message
  list            - List all available endpoints
  status (info)   - Show switcher status and current server info
  switcher        - Interactively manage switcher
  endpoint        - Interactively manage endpoint
  exit/quit (q)   - Close the admin connection

Available Endpoint Commands:
  help (?)        - Show this message
  list            - List all available endpoints
  add ip:port     - Adds one or more endpoints
                      Use 'ip:port ip:port' with out qotes to add multiple
  remove (rm) <n> - Remove endpoint by ID
  set <n>         - Manually set the active endpoint ID
  find ip:port    - Find ID from the address 
  status (info)   - Show switcher status and current server info
  switcher        - Interactively manage switcher 
  return (ret)    - Return to global session state
  exit/quit (q)   - Close the admin connection

Available Switcher Commands:
  help (?)        - Show this message
  status (info)   - Show switcher status and current server info
  play            - Resume/start the switcher thread
  pause           - Suspend the switcher thread
  kill            - Completely stop the switcher thread
  timer           - Set timer duration for siwtcher thread
  endpoint        - Interactively manage endpoint
  return (ret)    - Return to global session state
  exit/quit (q)   - Close the admin connection

```

---
## Credits

- Adjusted loging timestamp support provided by [ehrktia's zig-epoch](https://github.com/ehrktia/zig-epoch)

## Development

* Requires [Zig 0.17.0-dev+](https://ziglang.org/download/)
* Uses Zig standard library only.
* Source files are in the `src/` directory.
* Build script: `build.zig`

---

## License 
This project is licensed under the GNU GPL 2.0. See [LICENSE](LICENSE) for details.

---

## Contributing

Feel free to submit issues or pull requests.
Bug reports and feature requests are welcome!

---

## Contact

For questions or help, please open an issue or contact the author.

```
miagi@vivaldi.net
```
