# wg-forwarder
WireGuard helper for seamless endpoint host switching 

---

## WIP
Change configuration file to yaml at some point (implement yaml parsing).

Copy default config template and service file on installation step. 

Fix a posible memory leak in readFile function. Needs refactor of parser.zig or changing an allocator.

---
## Usage/Flags
```
-c <config_path>
```

---

## Configuration
Currently supports json formatting.  client_socket should be named client_endpoint - WIP
Example:
```
{
  "client_socket": {
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
  },
  "log_level": "info"
}

```
- when switcher enabled is set to false, it would skip the switcher thread and ignore auto switching endpoints.
- timer can be omitted if the switcher is set to false. Otherwise it would panic - WIP
- log_level can be ommited, it will use zig's default log level in that case.
- id is used to set an initial server endpoint. 

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
