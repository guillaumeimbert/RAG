# How to point the app at an inference server

RAGuesslighter speaks plain HTTP to an OpenAI-compatible API. It needs
two endpoints: `/embeddings` (ingest) and `/chat/completions`
(`ask`). Both default to `OPENAI_BASE_URL` + `OPENAI_API_KEY`.

## Use a different chat server or model

Set in `.env`:

```
OPENAI_BASE_URL=http://localhost:8000/v1   # must end in /v1
OPENAI_API_KEY=not-needed                   # any non-empty string locally
LLM_MODEL=your-model-name
```

Local servers (vLLM, llama.cpp, ninfer) ignore the key but require it
to be non-empty. Test the wiring:

```sh
dune exec bin/query.exe -- ask "hello"
```

On an empty store this embeds the query and prints `no results` — if
you see that, the **embeddings** endpoint is reachable (a connection
refused or 404 means the URL or the `/v1` suffix is wrong). On a
populated store the run also calls the **chat** endpoint; a model
error there means `LLM_MODEL` is not what that server serves.

## Serve embeddings from a different server

```
OPENAI_BASE_URL=http://localhost:1234/v1
LLM_MODEL=qwen3.8-27b
OPENAI_EMBED_BASE_URL=http://192.168.1.21:1234/v1
OPENAI_EMBED_API_KEY=not-needed
EMBEDDING_MODEL=qwen3-embedding-4b
EMBEDDING_DIM=2560
```

When `OPENAI_EMBED_BASE_URL` is absent, embeddings use the chat
endpoint and key.

## Change the embedding model

1. Set `EMBEDDING_MODEL` to the model the server serves.
2. Set `EMBEDDING_DIM` to that model's output dimension.
3. Match the `vector(N)` column in `schema/0001_init.sql`.
4. Reset the store and re-ingest — existing vectors cannot be
  converted, and mixing dimensions in one column is an error.

See [how to manage the database](database.md#change-the-embedding-dimension)
for the reset steps.

## Requirements of the server

- `POST /embeddings` returning `data[].embedding` as float arrays of
  `EMBEDDING_DIM` dimensions.
- `POST /chat/completions` returning the standard OpenAI shape
  (`choices[0].message.content`).
- Nothing else. The app assumes no auth scheme beyond the
  `Authorization: Bearer <key>` header, no streaming, no tool calls.