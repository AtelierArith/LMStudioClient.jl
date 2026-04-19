# Model Management

## Check Server Status

```julia
using LMStudioClient

client = Client()
status = server_status(client)
println(status.reachable)
```

## List Downloaded Models

```julia
models = list_models(client)
for model in models
    println(model.key)
end
```

## List Loaded Models

```julia
loaded = list_loaded_models(client)
for item in loaded
    println(item.instance_id)
end
```

## Unload A Model

```julia
result = unload_model(client, "google/gemma-4-e2b:1")
println(result.instance_id)
```
