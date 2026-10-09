---
name: fences
---
1. A fence indented three spaces under a list item:

   ```bash
{{include lib/snippets/never.md}}
   ```

A tilde fence:

~~~
{{include lib/snippets/never.md}}
~~~

A backtick fence closed by a longer run:

```
{{include lib/snippets/never.md}}
`````

A tilde fence that a backtick line does not close:

~~~markdown
```
{{include lib/snippets/never.md}}
```
~~~

## Real Snippet

Expanded for `fences`.

Only the last directive is outside every fence.
