# Vault: hybrid search and saving notes

Date: 26 October 2026. Branch: `vault-hybrid`.

## The goal

Sanketa must search all the shelves of the vishalakshi vault by words and by meaning. Sanketa must also save text in the vault. The keyword search of `VaultSearch` stays as the fallback.

## Two options

- **Option A.** Sanketa talks to the MCP server of vishalakshi. Search uses the tool `federate`. Saving uses the tool `note`.
- **Option B.** Sanketa encodes the query in Swift with the model2vec model. Then `adhara_hybrid` gets a real vector. Saving still needs Python.

## Measurements

All numbers are from this Mac (26 October 2026), on the real vault (406 MB, 3361 documents on the main shelf, 272 on `ramabana`).

| What | Number |
|---|---|
| Keyword search in Swift (`VaultSearch`) | 9 to 23 ms |
| Server start, stdio, to the `initialize` reply | 1.1 to 1.4 s |
| First `federate` after the start (the encoder loads) | 0.34 to 1.4 s |
| `federate` after that, all shelves | 57 to 65 ms |
| `search`, main shelf only | 15 to 17 ms |
| Server memory (RSS) | 265 MB; 410 MB after many queries over HTTP |
| First `note` on a new temporary vault, with the server start | 1.65 s |
| Hybrid search on that vault after the save | 14 ms |
| Old `vishalakshi-mcp` 0.1.1 in `~/.local/bin` | 34 s start, 6 to 15 s each search, 2.5 GB |

For option B, the model files are 512 MB of float32 weights and an 18.6 MB `tokenizer.json`. The Swift tokenizer must give the same tokens as the Python tokenizer, or the vectors do not match the vectors in the vault.

## The decision: option A

1. Option A gives search and saving with one connection. Option B gives search only.
2. A warm hybrid search takes about 60 ms. This is fast enough for a search that waits 0.2 s for the user to stop typing.
3. Option B puts 512 MB of weights in Sanketa, and it has a risk that the tokens are different. Its gain is the start time, about 1.5 s, one time in 10 minutes.

Option B can be a later change, if the start time becomes a problem.

## Changes from the first plan

- **Standard input and output, not HTTP.** `vishalakshi-mcp --http` always listens on port 8000. The environment variable `FASTMCP_PORT` has no effect, because vishalakshi makes the server with the default port. A fixed port can be in use, and another program can take it. Thus Sanketa starts the server as a child process and talks to it on its standard input and output. The child stops when Sanketa stops it, after 10 minutes with no search, or when Sanketa quits. `mcp_url` connects to a server that runs already, over Streamable HTTP. Sanketa accepts only an address on this Mac.
- **The shelves.** Sanketa reads the list of shelves from the vault file. It removes the `tmp*` and `dialogprobe*` shelves and the empty shelves. Then it gives the list to `federate`. The code legs of `federate` (`repo`, `grep`, `env`) are off.
- **Titles.** A hit of `federate` has a section title, such as "Pages 1–1: …". Sanketa shows the title of the document from the vault file.

## How it works

- Search is off the main thread and waits 0.2 s after the last key. If the server is not ready, the search uses keywords, and it starts the server for the next search. The panel also starts the server when a search starts. A hybrid search stops after `mcp_timeout_seconds` (1 s). Then Sanketa uses the keyword results. A server that fails to start is not tried again for 60 s. A save tries again at once.
- `federate` gives the hits in order of RRF rank. Sanketa keeps this order. Search then ranks the vault results with the pack results, by their match with the title and the text.
- ⌘S saves the query. ⌘D saves the clipboard, with the query as the title. Each save has a new key, so it never replaces a note with the same title. Only these two keys save.
- `[abhyasa]` is off by default. Then Sanketa makes no abhyasa link and never connects to abhyasa. On, Sanketa asks `GET /health` (at most one time in 10 s) before it makes a link.

## Known limits

- RRF gives the first hit of each shelf the same score. Thus each shelf shows its best hits, also when they are not good. An example is the `news` shelf for the query "tmux pane".
- `federate` hides personal data (`pii = redact`). A result can show `[EMAIL]` in place of an address.
- The Edit menu and ⌥Return have unit tests only. Nobody tested them in the running app.
