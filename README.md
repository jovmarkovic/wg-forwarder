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
  "address_family": "ip4",
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
    "timer": 12,
    "endpoints": [
      "192.168.1.4:8921",
      "100.116.14.17:8921"
    ]
}

```
- when switcher enabled is set to false, it would skip starting the switcher thread and ignore auto switching endpoints.
- server_socket structure can be omitted. Defaults for it are: address: "0.0.0.0/::1", port: 0
- timer can be omitted if the switcher is set to false. Otherwise it would panic 
- log_level can be omitted, it will use Zig's default log level in that case.
- address_family can be ommited, default is ip4.
- id is used to set an initial server endpoint. 

## Explanation
- log_level: Runtime logging level of the service.
- address_family: Runtime network family version of the service.
- client_endpoint: Endpoint of the wireguard client that wants to send packets to a server.

  Packets that arrive from a different endpoint are dropped with a warning.
- forwarder_socket: Socket that accepts packets from client_endpoint. 

  In WireGuard client configuration you need to specify this as a peer endpoint for a server
- server_socket: Socket that accepts from and sends packets to server. 
  
  When not set, kernel will decide which port to use and listen on all addresses.

- switcher: function that does seamless endpoint switching. It uses interval set in `timer` with a 2s failover window.
  
  Failover is meant to speed up the process of finding responsive endpoint.
  If set to false, use ID to set the index of your desired server endpoint.
  Packets that arrive from a different endpoint are dropped with a warning.

# NOTE:
  Wireguard's `KEEPALIVE_TIMEOUT` is 10s after the end of stream. 
  `timer` should be longer than it unless `PersistentKeepalive` flag is set explicitly in its config.


## Configuration types
- log_level: err, warn, info, debug

- address_family: union(enum) ip4, ip6

- address: IPv4, IPv6

- port: u16

- timer: (u32) seconds 

- id: u32

- enabled: bool

- endpoints: [ "IPv4/[IPv6]:port", "IPv4/[IPv6]:port", ... ,"IPv4/[IPv6]:port" ]

---

## Credits

- Adjusted loging timestamp support provided by [ehrktia's zig-epoch](https://github.com/ehrktia/zig-epoch)

## Development

* Requires [Zig 0.16.0](https://ziglang.org/download/)
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
