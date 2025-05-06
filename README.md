# Envoy + JWT + Trino

We need to pass to _Trino_ the user that is making the call, but the user comes in the claims of the _JWT_. _Trino_ by default is not capable of receiving a _JWT_ and to the extraction.

_Trino_ expose a *REST API* through we can do the following:

- Query the distribute _datasources_ trino abstract by his `catalogs`

    > /v1/statement

- Query the status of the _Trino_ cluster.

    > /v1/info

- Query the status of any operation submitted.

    > /v1/query/{query-id}

_Trino_ queries support a set of headers [Trino-Headers](https://trino.io/docs/current/develop/client-protocol.html#client-request-headers). But one that is mandatory is the `X-Trino-User` which represent the user requesting the query operation. The idea of the setup of this repository is to provide this user from a _JWT_ token.

## Architecture

Because _Trino_ is not able to extract the user from _JWT_ we implement a _proxy laver_ using `Envoy`. The role of _Envoy_ is to play as a proxy/load balancer/JWT handling in this setup.

_Envoy_ will recive any request targeting _Trino_ and depending of the endpoint requested, will enforce the _JWT_ validation, user extraction and injection of this user in the `X-Trino-User` header of the upstream request.

![Architecture](images/architecture.png)

### Request/Response flow

All start by a user/system requesting a query againts any _datasource_ managed by _Trino_. But _Trino_ will be behind _Envoy_ which will act as a **Proxy/Load balancer**. So the request will hit _Envoy_ first, which will be exposed on port `8888`

> 'http://localhost:8888/v1/statement

Note that `localhost:8888` is the address where `Envoy` will be listening to any kind of request _(in this demo http request)_.

```
    static_resources:
        listeners:
            - name: listener_0
            address:
                socket_address:
                address: 0.0.0.0
                port_value: 8888
```

 _Envoy_ will process this request according to his `config-routing` inside his `filter_chains`.

```
    filter_chains:
        - filters:
            - name: envoy.filters.network.http_connection_manager
              typed_config:
                "@type": type.googleapis.com/envoy.extensions.filters.network.http_connection_manager.v3.HttpConnectionManager
                stat_prefix: ingress_http
                route_config:
                  name: local_route
                  virtual_hosts:
                    - name: trino_service
                      domains: ["*"]
                      routes:                        
                        - match:
                            path: "/v1/statement"
                          route:
                            cluster: trino                          
                        - match:
                            prefix: "/"
                          route:
                            cluster: trino
                          typed_per_filter_config:
                            envoy.filters.http.ext_authz:
                              "@type": type.googleapis.com/envoy.extensions.filters.http.ext_authz.v3.ExtAuthzPerRoute                              
                              disabled: true
```

 And will apply the set of `http-filters` configured to the upstream request.

 ```
    http_filters:                  
        - name: envoy.filters.http.ext_authz
        typed_config:
            "@type": type.googleapis.com/envoy.extensions.filters.http.ext_authz.v3.ExtAuthz
            http_service:
            server_uri:
                uri: http://auth_service:8081
                cluster: auth_service
                timeout: 5.25s
            path_prefix: /api/validate            
            authorization_response:
                allowed_upstream_headers:
                patterns:
                    - exact: x-trino-user
            failure_mode_allow: false
            clear_route_cache: true
        - name: envoy.filters.http.router
        typed_config:
            "@type": type.googleapis.com/envoy.extensions.filters.http.router.v3.Router
 ```

 So what all of this means?. Let see step by step:

 1. User send a request to trino, but _Envoy_ is his proxy, so the request will reach _Envoy_ first.

    ```
        curl --location 'http://localhost:8888/v1/statement' \
        --header 'Authorization: Bearer eyJhbGciOiJSUzI1NiIsInR5cCI6IkpXVCIsImtpZCI6IlRWQTVRam9oWjg4TDAxdmlDM0ppNyJ9.eyJpc3MiOiJodHRwczovL2Rldi0yMGVmMDFyaWJtdXRnYnI1LnVzLmF1dGgwLmNvbS8iLCJzdWIiOiJxckNzTHhGUFZib2ozdlFhaklFUVVXT2VMeDQ4MlpjY0BjbGllbnRzIiwiYXVkIjoiaHR0cHM6Ly90ZXN0LWFwaSIsImlhdCI6MTc0NjQwOTQ2NSwiZXhwIjoxNzQ2NDk1ODY1LCJndHkiOiJjbGllbnQtY3JlZGVudGlhbHMiLCJhenAiOiJxckNzTHhGUFZib2ozdlFhaklFUVVXT2VMeDQ4MlpjYyJ9.Ngq8vv0uqhm_NfrUGKep3utp2Eu2_-_LbDitOT_EdGs8y-wCrEVhq6glQMsgO4f274p3bjlKzbfrdg0UV2YgiKAn0wbf5Him_KkCAP8XU2d7Nuf4qm9Y1I7s5QUAkPO7h0pNfZhAQe8tGp7x8yxPmAbbJIx6oyeu6uBq3cOJN5sXSIOcHiAo0wli_KIlNFbgpnMUCSlAvkZcpkyHmx9CnUSSK2Lky4RV7izutHdg559vZxOcss-ImgRkZ2YvSXstysf79nK2PI9Zn0rCvHIqsdEnIGsk9cHJtpv5iIJVpPcGqOqONm7GDEAy5qHz7G_wapshgdRgqid6IupTrCZpdg' \
        --header 'Content-Type: text/plain' \
        --data 'SELECT * FROM mysql.test1.app_user LIMIT 10'
    ```

2. Envoy based in this routing configurations will determine what `filters` to applied to the upstream request before sending it  to a specific `cluster`.

    ```
        routes:                        
            - match:
                path: "/v1/statement"
                route:
                cluster: trino
            - match:
                prefix: "/"
                route:
                cluster: trino
                typed_per_filter_config:
                envoy.filters.http.ext_authz:
                    "@type": type.googleapis.com/envoy.extensions.filters.http.ext_authz.v3.ExtAuthzPerRoute                              
                    disabled: true
    ```


    In this case the request match the first route.

3. The section `http_filters` specify what _filter-chain_ will be applied to the request that match any route. In this case _Envoy_ has configured two filters

    - **envoy.filters.http.ext_authz**
    - **envoy.filters.http.router**

4. `envoy.filters.http.ext_authz` is a filter that is capable of calling an external authentication service using **HTTP** or **GRPC**. In this setup he will call an externar _REST API_ endpoint to delegate the authentication.

    ```
        http_filters:                  
            - name: envoy.filters.http.ext_authz
            typed_config:
                "@type": type.googleapis.com/envoy.extensions.filters.http.ext_authz.v3.ExtAuthz
                http_service:
                server_uri:
                    uri: http://auth_service:8081                    
                    cluster: auth_service
                    timeout: 5.25s
                path_prefix: /api/validate                
                authorization_response:
                    allowed_upstream_headers:
                    patterns:
                        - exact: x-trino-user
                failure_mode_allow: false
                clear_route_cache: true
    ```

    As depicted above, the uri of the external service is `http://auth_service:8081//api/validate` (this is the repo fo this REST API [JWT-Validation](https://github.com/josemorareailize/JWT-Validator)) and how to reach to this service is defined in the `cluster` _auth_service_.

    ```
        - name: auth_service
            connect_timeout: 0.25s
            type: strict_dns
            lb_policy: round_robin
            load_assignment:
                cluster_name: auth_service
                endpoints:
                - lb_endpoints:
                    - endpoint:
                        address:
                            socket_address:
                            address: auth_service
                            port_value: 8081
    ```
    __Envoy__ will send the `Authentication` header in the request and expect the external endpoint to return two thing.

        - If _JWT_ is valid (decode token, validates his signature using the public key exposed in the JWKS exposed in the kid claim of the token and validate if the tenant (iss) is amoung the tenants allowed), which will means authentication sucessful depicted by status code `HTTP OK` or authentication unsuccess by status code `400` or `500`.
        - Add a trino specific header `X-Trino-User` set with the username that is extracted from username claim form the _JWT_ token.

5. If authentication fails, _Envoy_ will reject the upstream request with a `403 Forbidden` status code. But if authentication is successful, will pass the upstream request to the next `http_fiter`.

6. `envoy.filters.http.router` is a filter responsable of doing routing of the upstream request to the intended target, which is specified in the destination `cluster` configured on the _Envoy_ routing configuration.

7. The corresponding `Cluster` assigned to the upstream request has all the information of the target of the request, so the request is forwarded to it.

    ```
        clusters:
            - name: trino
                connect_timeout: 0.25s
                type: strict_dns
                lb_policy: round_robin
                load_assignment:
                    cluster_name: trino
                    endpoints:
                    - lb_endpoints:
                        - endpoint:
                            address:
                                socket_address:
                                address: trino
                                port_value: 8080
    ```

## Trino

_Trino_ does not execute the queries submitted by a request immediately in a synchonous way instead he follows what he calls an `asynchronous chunked  execution model` where he returns intermediate response of the status of the call until the call is finally resolved. The idea of doing this if for:

- Long-running queries​
- Better scalability​
- Streaming of results​
- Status tracking and cancellation​

So when the request to `/v1/statement` is received by _Trino_, he respond back with:

- An **Id** assigned to the query.
- **InfoUri** to see information of the current query in the web UI of _Trino_. Requires authentication.
- **NextUri** A url composed by the **Id** of the request and is used to follow the process of the execution of the query.
- **Stats** about the query in the current chunk.

So the pattern is to follow the **NextUri** which start in state `QUEUED` until you get to state `FINISHED` where you will see the result of the query. If for any reason the query fails, the state will be `FAILURE`.

### Execution flow example

1. Query requested to get all app_users from catalog `mysql`.
    > SELECT * FROM mysql.test1.app_user LIMIT 10

2. Query send in the body of the request to `/v1/statement`.
3. _Trino_ receive the request in his `coordinator node` generates the execution plan and distribute the query splitted in form of `Task` to a set of `Workers Node` to fulfill the request. It return to the user the following answer.

    ```
        {
        "id": "20250506_053029_00002_h3bdt",
        "infoUri": "http://localhost:8080/ui/query.html?20250506_053029_00002_h3bdt",
        "nextUri": "http://localhost:8080/v1/statement/queued/20250506_053029_00002_h3bdt/yd6956f4f4623c1256d4ee19595db899e5e74480d/1",
        "stats": {
            "state": "QUEUED",
            "queued": true,
            "scheduled": false,
            "nodes": 0,
            "totalSplits": 0,
            "queuedSplits": 0,
            "runningSplits": 0,
            "completedSplits": 0,
            "planningTimeMillis": 0,
            "analysisTimeMillis": 0,
            "cpuTimeMillis": 0,
            "wallTimeMillis": 0,
            "queuedTimeMillis": 0,
            "elapsedTimeMillis": 0,
            "finishingTimeMillis": 0,
            "physicalInputTimeMillis": 0,
            "processedRows": 0,
            "processedBytes": 0,
            "physicalInputBytes": 0,
            "physicalWrittenBytes": 0,
            "internalNetworkInputBytes": 0,
            "peakMemoryBytes": 0,
            "spilledBytes": 0
        },
        "warnings": []
    }
    ```

4. User will need to send a request using the value on `nextUri`
    > http://localhost:8080/v1/statement/queued/20250506_053029_00002_h3bdt/yd6956f4f4623c1256d4ee19595db899e5e74480d/1
5. In this moment is when _Trino_ start processing the request and return back the current status of the request.

    ```
        {
        "id": "20250506_053029_00002_h3bdt",
        "infoUri": "http://localhost:8080/ui/query.html?20250506_053029_00002_h3bdt",
        "nextUri": "http://localhost:8080/v1/statement/executing/20250506_053029_00002_h3bdt/yc5b190ee84d8869a2a487f0ddb367692e20b6e79/0",
        "stats": {
            "state": "QUEUED",
            "queued": true,
            "scheduled": false,
            "nodes": 0,
            "totalSplits": 0,
            "queuedSplits": 0,
            "runningSplits": 0,
            "completedSplits": 0,
            "planningTimeMillis": 0,
            "analysisTimeMillis": 0,
            "cpuTimeMillis": 0,
            "wallTimeMillis": 0,
            "queuedTimeMillis": 1,
            "elapsedTimeMillis": 48129,
            "finishingTimeMillis": 0,
            "physicalInputTimeMillis": 0,
            "processedRows": 0,
            "processedBytes": 0,
            "physicalInputBytes": 0,
            "physicalWrittenBytes": 0,
            "internalNetworkInputBytes": 0,
            "peakMemoryBytes": 0,
            "spilledBytes": 0
        },
        "warnings": []
    }
    ```
6. So keep following the `nextUri` until no more `nextUri` present in the request. In the below response we see the status is already `FINISHED` by their is another `nextUri`. The data of the request is found in the **data** attribute of the json response.

```
    {
        "id": "20250506_053029_00002_h3bdt",
        "infoUri": "http://localhost:8080/ui/query.html?20250506_053029_00002_h3bdt",
        "nextUri": "http://localhost:8080/v1/statement/executing/20250506_053029_00002_h3bdt/y5ffd5927a258f3b6be0d3b825fae71e80d9bd166/1",
        "columns": [
            {
                "name": "id",
                "type": "integer",
                "typeSignature": {
                    "rawType": "integer",
                    "arguments": []
                }
            },
            {
                "name": "username",
                "type": "varchar(100)",
                "typeSignature": {
                    "rawType": "varchar",
                    "arguments": [
                        {
                            "kind": "LONG",
                            "value": 100
                        }
                    ]
                }
            }
        ],
        "data": [
            [
                1,
                "jose"
            ],
            [
                2,
                "Alejandro"
            ]
        ],
        "stats": {
            "state": "FINISHING",
            "queued": false,
            "scheduled": true,
            "progressPercentage": 100.0,
            "runningPercentage": 0.0,
            "nodes": 1,
            "totalSplits": 1,
            "queuedSplits": 0,
            "runningSplits": 0,
            "completedSplits": 1,
            "planningTimeMillis": 122,
            "analysisTimeMillis": 55,
            "cpuTimeMillis": 17,
            "wallTimeMillis": 21,
            "queuedTimeMillis": 1,
            "elapsedTimeMillis": 53992,
            "finishingTimeMillis": 1,
            "physicalInputTimeMillis": 2,
            "processedRows": 2,
            "processedBytes": 0,
            "physicalInputBytes": 0,
            "physicalWrittenBytes": 0,
            "internalNetworkInputBytes": 0,
            "peakMemoryBytes": 162,
            "spilledBytes": 0,
            "rootStage": {
                "stageId": "0",
                "state": "FINISHED",
                "done": true,
                "nodes": 1,
                "totalSplits": 1,
                "queuedSplits": 0,
                "runningSplits": 0,
                "completedSplits": 1,
                "cpuTimeMillis": 17,
                "wallTimeMillis": 21,
                "processedRows": 2,
                "processedBytes": 0,
                "physicalInputBytes": 0,
                "failedTasks": 0,
                "coordinatorOnly": false,
                "subStages": []
            }
        },
        "warnings": []
    }

```
7. Following the `nextUri` in the above request, get us to the final status of the query and all of this stats.

```
    {
        "id": "20250506_053029_00002_h3bdt",
        "infoUri": "http://localhost:8080/ui/query.html?20250506_053029_00002_h3bdt",
        "columns": [
            {
                "name": "id",
                "type": "integer",
                "typeSignature": {
                    "rawType": "integer",
                    "arguments": []
                }
            },
            {
                "name": "username",
                "type": "varchar(100)",
                "typeSignature": {
                    "rawType": "varchar",
                    "arguments": [
                        {
                            "kind": "LONG",
                            "value": 100
                        }
                    ]
                }
            }
        ],
        "stats": {
            "state": "FINISHED",
            "queued": false,
            "scheduled": true,
            "progressPercentage": 100.0,
            "runningPercentage": 0.0,
            "nodes": 1,
            "totalSplits": 1,
            "queuedSplits": 0,
            "runningSplits": 0,
            "completedSplits": 1,
            "planningTimeMillis": 122,
            "analysisTimeMillis": 55,
            "cpuTimeMillis": 17,
            "wallTimeMillis": 21,
            "queuedTimeMillis": 1,
            "elapsedTimeMillis": 53993,
            "finishingTimeMillis": 2,
            "physicalInputTimeMillis": 2,
            "processedRows": 2,
            "processedBytes": 0,
            "physicalInputBytes": 0,
            "physicalWrittenBytes": 0,
            "internalNetworkInputBytes": 0,
            "peakMemoryBytes": 162,
            "spilledBytes": 0,
            "rootStage": {
                "stageId": "0",
                "state": "FINISHED",
                "done": true,
                "nodes": 1,
                "totalSplits": 1,
                "queuedSplits": 0,
                "runningSplits": 0,
                "completedSplits": 1,
                "cpuTimeMillis": 17,
                "wallTimeMillis": 21,
                "processedRows": 2,
                "processedBytes": 0,
                "physicalInputBytes": 0,
                "failedTasks": 0,
                "coordinatorOnly": false,
                "subStages": []
            }
        },
        "warnings": []
    }
```
