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
}

```
- when switcher enabled is set to false, it would skip the switcher thread and ignore auto switching endpoints.
- timer can be omitted if the switcher is set to false. Otherwise it would panic 
- log_level can be ommited, it will use zig's default log level in that case.
- id is used to set an initial server endpoint. 

## Explanation
- log_level: Runtime logging level of the service.
- client_endpoint: Endpoint of the wireguard client that wants to send packets to a server.
- forwarder_socket: Socket that accepts packets from client_endpoint. 

  In WireGuard client configuration you need to specify this as a peer endpoint for a server
- server_socket: Socket that accepts packets from server.
- switcher: function that does seamless endpoint switching. 

  If set to false, use ID to set the index of your desired server endpoint.

## Options
log_level: err, warn, info, debug

addres: IPv4

port: u16

timer: seconds

id: usize (u32 on x86 / u64 on x64)

enabled: bool

endpoints: [ "IPv4:port", "IPv4:port", ... ,"IPv4:port" ]

---

## Development

* Requires [Zig 0.16.0-dev+](https://ziglang.org/download/)
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
