# s3-contract-check

Checks an S3-compatible storage against what skein-api needs from it. It uses
the same presign logic as `skein-api/src/internal/attachments/client.go`
(minio-go v7), so a green run means the browser's attachment flow works
against that storage.

It is **not** part of any automatic run. Run it by hand when:

- you change the pinned image of a bundled store (Garage, SeaweedFS, RustFS) in
  `docker-compose.production.yml`;
- you add a store or an external S3 to the supported list;
- someone reports attachments failing against their own S3.

The default store, Garage, is also covered by `./scripts/e2e-test.sh`; the other
stores are covered only by this check.

## Checks

Each prints one line, `PASS|FAIL|SKIP <id> <name> <detail>`; the exit code is 1
if any check fails.

| id | what |
|---|---|
| 1 | browser-style multipart POST to the presigned policy, exact declared size |
| 2 | size +1 and -1 are rejected and the object is not stored |
| 3 | wrong content type and wrong key are rejected |
| 4 | expired policy is rejected |
| T | policy changed after signing, and a wrong signature, are rejected |
| 5 | presigned GET returns the bytes with the requested `Content-Disposition` (Cyrillic name) |
| 6 | CORS: preflight and POST/GET responses carry `Access-Control-*` for the origin, not for a foreign one |
| 7 | Stat of an existing and a missing object |
| 8 | Remove of an existing, a repeated and a missing object returns no error |
| 9 | recursive listing returns every key (300 objects) |
| 10 | BucketExists, MakeBucket, ListBuckets |
| 11 | signature with the configured region is accepted |
| 12 | cluster only: write through one node, read through another (`S3_NODES`) |

## Run

On a test machine, in a container, never against production data. The bucket
must already exist and the key must be able to read and write it.

```bash
cd scripts/s3-contract-check
docker run --rm --user "$(id -u):$(id -g)" -e HOME=/w/home -e GOCACHE=/w/home/cache \
  -e GOPATH=/w/home/gopath -e CGO_ENABLED=0 -v "$PWD:/w" -w /w golang:1.26 \
  go build -o s3check .
docker run --rm --network <network of the store> -v "$PWD:/b:ro" \
  -e S3_ENDPOINT=garage:3900 -e S3_ACCESS_KEY=... -e S3_SECRET_KEY=... \
  -e S3_SET_CORS=1 -e S3_ORIGIN=http://localhost:8080 \
  golang:1.26 /b/s3check
```

| Variable | |
|---|---|
| `S3_ENDPOINT` | `host:port`, required |
| `S3_PUBLIC_ENDPOINT` | endpoint the browser uses; default = `S3_ENDPOINT` |
| `S3_ACCESS_KEY`, `S3_SECRET_KEY` | the key skein-api would use |
| `S3_BUCKET` | default `skein-attachments`; must exist |
| `S3_REGION` | default `us-east-1` |
| `S3_SECURE` | `1` for https |
| `S3_ORIGIN` | browser origin for check 6; default `http://localhost:8080` |
| `S3_SET_CORS` | `1`: set the bucket CORS rule before check 6 (as skein-api does at startup) |
| `S3_LIMITED_ACCESS_KEY`, `S3_LIMITED_SECRET_KEY` | a key without the create-bucket right, for check 10 |
| `S3_NODES` | `host1:port,host2:port`, enables check 12 |

Other subcommands: `setcors`, `mkbucket`, `big` (500 MB POST of random data;
`REPS=n`, `KEEP=1`), `listload` (200 objects x 300 recursive lists), `rm <key..>`,
`rw <key>` (PUT, STAT, GET through one endpoint, for probing a node that is
down), `stat <key>`, `extra` (CORS headers on the POST response; POST with a
required field omitted).
