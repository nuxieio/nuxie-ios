# Flow Runtime Trace Format (v1)

This fixture trace format is renderer-neutral and intended for parity runs across
React today and future Rive renderer adapters.

```json
{
  "schemaVersion": 1,
  "fixtureId": "fixture-nav-binding",
  "rendererBackend": "react",
  "entries": [
    {
      "step": 1,
      "kind": "navigation",
      "name": "navigate",
      "screenId": "screen-2",
      "output": "screen-2",
      "metadata": null
    },
    {
      "step": 2,
      "kind": "binding",
      "name": "did_set",
      "screenId": "screen-2",
      "output": "{\"path_ids\":[1,2,3],\"value\":{\"title\":\"Hello\"}}",
      "metadata": {
        "source": "input"
      }
    },
    {
      "step": 3,
      "kind": "event",
      "name": "$flow_shown",
      "screenId": "screen-2",
      "output": "{\"campaign_id\":\"camp-e2e-1\",\"flow_id\":\"flow-e2e\"}",
      "metadata": null
    }
  ]
}
```

Field notes:

- `schemaVersion`: Version gate for breaking trace format changes.
- `fixtureId`: Stable identifier for the canonical fixture scenario.
- `rendererBackend`: Adapter/backend under test (`react`, `rive`, etc.).
- `entries`: Ordered runtime outputs.
  - `kind=event`: Analytics events tracked by runtime.
  - `kind=navigation`: Runtime navigation or screen-change observations.
  - `kind=binding`: Key binding outputs (`action/did_set`) including path/value.
