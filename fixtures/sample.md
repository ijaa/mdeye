# Hello from fixtures

This is a **sample** Markdown file for MDEye **full** pack.

## Lists

- item one
- item two

### Tasks

- [x] Offline reading
- [x] Mermaid bundled

## Code

```js
function greet(name) {
  return `hello ${name}`;
}
```

## Table

| Feature | Status |
| ------- | ------ |
| GFM     | yes    |
| Themes  | yes    |
| Mermaid | yes    |

## Mermaid

```mermaid
graph LR
  A[Open .md] --> B[Render]
  B --> C[Read]
  C --> D[Done]
```

```mermaid
sequenceDiagram
  participant U as User
  participant M as MDEye
  U->>M: Double-click file.md
  M-->>U: Rendered preview
```
