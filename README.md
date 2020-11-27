# Haskell client library for Logstash

![MIT](https://img.shields.io/github/license/mbg/logstash)
![CI](https://github.com/mbg/logstash/workflows/Build/badge.svg?branch=master)

This library implements a client for Logstash in Haskell. For example, to connect to a Logstash server via TCP at `127.0.0.1:5000` (configuration given by `def`) and send a JSON document with a timeout of 30s:

```haskell
data Doc = Doc String

instance ToJSON Doc where
    toJSON (Doc msg) = object [ "message" .= msg ]

main :: IO ()
main = runLogstashConn (logstashTcp def) $
    stashJsonLine 30 (Doc "Hello World")
```

Only the `tcp` input type (with or without TLS) is currently supported. For example, without TLS, the Logstash input configuration should roughly be:

```conf
input {
    tcp {
        port => 5000
        codec => "json_lines"
    }
}
```

With TLS, the expected Logstash configuration should roughly be:

```conf
input {
    tcp {
        port => 5000
        ssl_cert => "/usr/share/logstash/tls/cert.pem"
        ssl_key => "/usr/share/logstash/tls/key.pem"
        ssl_key_passphrase => "foobar"
        ssl_enable => true 
        ssl_verify => false
        codec => "json_lines"
    }
}
```

## Configuring connections

Connections to Logstash are represented by the `LogstashConnection` type. To connect to Logstash via `tcp` use the `Logstash.TCP` module which exports four principal functions. Note that none of these functions establish any connections when they are called - instead, they allow `runLogstashConn` and `runLogstashPool` to establish connections/reuse them as needed:

- `logstashTcp` which, given a hostname and a port, will produce an `Acquire` that can be used with `runLogstashConn`.
- `logstashTcpPool` which, given a hostname and a port, will produce a `Pool` that can be used with `runLogstashPool`.
- `logstashTls` which, given a hostname, a port, and TLS client parameters, will produce an `Acquire` that can be used with `runLogstashConn`.
- `logstashTlsPool` which, given a hostname, a port, and TLS client parameters, will produce a `Pool` that can be used with `runLogstashPool`.

For `logstashTls` and `logstashTlsPool`, TLS `ClientParams` are required. It is worth noting that the `defaultParamsClient` function in the `tls` package does **not** set any supported ciphers by default. The following is therefore necessary to get it to work with e.g. `localhost`:
```haskell
localhostParams :: ClientParams
localhostParams = (defaultParamsClient "localhost" BS.empty){ 
    clientSupported = def{
        supportedCiphers = ciphersuite_default
    }
}
```

## Logging things

The `Logstash` module exports backend-independent logging functions that can be invoked with the help of one of the following two functions:

- `runLogstashConn` expects an `Acquire LogstashConnection` as its first argument and will establish the connection to the Logstash server. If the computation that is provided as the second argument terminates or throws an exception, the connection is closed.
- `runLogstashPool` expects a `Pool LogstashConnection` as its first argument. If a connection is available in the pool, that connection will be used. If no connection is available but there is an empty space in the pool, a new connection will be established. If neither is true, this function blocks until a connection is available. The computation that is provided as the second argument is then run with the connection. If it terminates or an exception is thrown, the connection is closed. In the event of an exception, the connection is not returned to the pool.

The following functions allow sending data via the Logstash connection:

- `stash` is a general-purpose function for sending `ByteString` data to the server. No further processing is performed on the data, but a timeout is applied after which sending the message is aborted.
- `stashJsonLine` is for use with the `json_line` codec. The argument is encoded as JSON and a `\n` character is appended, which is then sent to the server. A timeout is applied after which sending the message is aborted.
