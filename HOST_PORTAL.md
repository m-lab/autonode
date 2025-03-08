# Host Portals

Host organizations can create test portals that target only their servers.

Create a copy of [ndt7-js client example][ndt7-js]. Modify `metadata` to include
the [request parameters for your organization or server][locate].

For example:

```js
    ...
    metadata: {
        client_name: 'foo-ndt7-org-portal',
        org: 'foo',
    },
    ...
```

A portal can enumerate all known sites for an organization, using the Autojoin.List parameters:

* `https://autojoin.measurementlab.net/autojoin/v0/node/list?format=sites&org=foo`

```js
    ...
    metadata: {
        client_name: 'foo-ndt7-site-portal',
        site: 'bar12345',
    },
    ...
```

[locate]: https://github.com/m-lab/locate/blob/main/USAGE.md#additional-request-parameters
[ndt7-js]:
    https://github.com/m-lab/ndt7-js/blob/bd030adb13191b6e6ec7b6a03011c13971ae7ed6/examples/client.html#L18-L20
