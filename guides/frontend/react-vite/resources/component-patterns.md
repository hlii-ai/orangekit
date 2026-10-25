<!-- orangekit-pack: frontend/react-vite v3.36.0 -->
# Component Patterns

Rules for where a component goes in a React 18 + TypeScript SPA, when it is promoted to shared,
and what it is allowed to own.

## 1. The three tiers

| Tier | Location | Knows | Does not know |
| --- | --- | --- | --- |
| Page | `features/<f>/pages/` | route params, query hooks, layout assembly | detailed markup |
| Feature component | `features/<f>/components/` | this feature's domain types | other features, routing |
| Common component | `components/common/`, `components/layout/` | the visual contract (props) only | the domain, fetching, routing |

Rule: **dependencies flow downward only.** A shared component never imports from `features/`.
Break that direction and the shared component is tied to one feature, and its reuse is over.

## 2. Search before you build (the duty to look)

Most duplicate components come not from "we never extracted it" but from **"we did not know it existed"**.
Before building a shared candidate, search along at least two axes.

```bash
# ① The name axis — common names for the role you are after
rg -il "pageshell|emptystate|datatable|modal|drawer|badge" src/components src/features

# ② The markup axis — the class combination already in use
rg -l "rounded-lg border .* bg-white" src/components

# ③ Skim the shared directory listings (it takes 30 seconds)
ls src/components/common src/components/layout
```

If the search turns up something **similar but insufficient**, add one prop instead of building a new one.
Create a new file only once you judge the existing one cannot be extended, and record that judgment in the PR.

## 3. When to extract

- Extract when the same block of markup appears a **third** time (twice is coincidence, three times is a pattern)
- When **two or more features** use the same UI, promote it to `components/common/` at the second one
- If it repeats inside one feature only, keep it in `features/<f>/components/` — premature sharing produces
  an "omni-component" with an exploded prop list
- What gets extracted is the **markup and styling**. Data fetching·routing do not come along with it

```tsx
// ✅ A shared shell has slots and nothing else
export function PageShell({ title, actions, children }: PageShellProps) {
  return (
    <div className="mx-auto w-full max-w-5xl px-6 py-8">
      <header className="mb-6 flex items-center justify-between">
        <h1 className="text-xl font-semibold text-slate-900">{title}</h1>
        {actions}
      </header>
      {children}
    </div>
  );
}

// ❌ The shared shell knows the domain — unusable in the next feature
export function PageShell({ taskId }: { taskId: string }) {
  const { data } = useTaskQuery(taskId);           // fetching
  const navigate = useNavigate();                   // routing
  return <div>{data?.title}<button onClick={() => navigate('/tasks')} /></div>;
}
```

## 4. Ownership of design tokens

A shared component defines its own **height·typography·spacing·corner radius** and nothing else does. Call sites
choose only through `variant`/`size` props. Once call sites start overriding tokens with `className`,
the word "shared" becomes a lie and a design change turns into an edit-everything sweep.

```tsx
// ✅ Tokens are defined in one place, inside the component
const sizes = {
  sm: 'h-8 px-3 text-xs',
  md: 'h-10 px-4 text-sm',
  lg: 'h-12 px-6 text-base',
} as const;

export function Button({ size = 'md', variant = 'primary', className, ...rest }: ButtonProps) {
  return <button className={cn(base, sizes[size], variants[variant], className)} {...rest} />;
}

// ❌ The call site overrides the tokens — the size prop becomes meaningless and the spec scatters
<Button className="h-9 px-5 text-[13px] rounded-none" />
```

`className` is allowed only for **positional adjustments** (`mt-4`, `w-full`, `col-span-2`).
With a `tailwind-merge`-based `cn()` the later class wins, so this distinction survives only as a
documented agreement — it is caught in code review.

## 5. Lists and keys

```tsx
// ✅ The stable identifier the server gave you
{tasks.map((t) => <TaskCard key={t.id} task={t} />)}

// ❌ Index key — on sort·delete·optimistic insert the input state attaches to the wrong row
{tasks.map((t, i) => <TaskCard key={i} task={t} />)}
```

## 6. Optimize after measuring

`memo`/`useMemo`/`useCallback` cost comparison time and memory. The default is not to use them; attach them
after confirming the real re-render cost in the React DevTools Profiler. Two cases may be attached without
measuring: ① a callback/object passed to a `memo`'d child, ② list items numbering in the hundreds or more.

## 7. Extend by composition (slots instead of a prop explosion)

Keep adding props as options accumulate and the component absorbs the demands of every call site.
Open a slot and the component owns **only layout and tokens**, while the call site decides the content.

```tsx
// components/common/Field.tsx — owns the placement of label·error·hint and the accessibility wiring
type FieldProps = {
  label: string;
  htmlFor: string;
  error?: string;
  hint?: string;
  children: ReactNode;   // the call site supplies the input element
};

export function Field({ label, htmlFor, error, hint, children }: FieldProps) {
  const hintId = hint ? `${htmlFor}-hint` : undefined;
  const errorId = error ? `${htmlFor}-error` : undefined;
  return (
    <div className="space-y-1.5">
      <label htmlFor={htmlFor} className="block text-sm font-medium text-slate-700">
        {label}
      </label>
      <div aria-describedby={cn(hintId, errorId)}>{children}</div>
      {hint && !error && <p id={hintId} className="text-xs text-slate-500">{hint}</p>}
      {error && <p id={errorId} role="alert" className="text-xs text-danger-600">{error}</p>}
    </div>
  );
}
```

```tsx
// Call site — Field does not change as the kinds of input grow
<Field label="Title" htmlFor="title" error={fieldErrors.title?.[0]} hint="At least 2 characters">
  <input id="title" className="h-10 w-full rounded-md border px-3 text-sm" />
</Field>

<Field label="Assignee" htmlFor="assignee">
  <select id="assignee" className="h-10 w-full rounded-md border px-3 text-sm">…</select>
</Field>
```

```tsx
// ❌ Props grow with every kind of input — and grow again with the next request
<Field label="Assignee" type="select" options={users} multiple searchable
       renderOption={...} inputProps={{...}} selectProps={{...}} />
```

Apply the same principle to lists. Take the header·body·empty state as slots and a single `DataTable`
serves every feature — the call site passes only the column definitions.

```tsx
type Column<T> = { key: string; header: ReactNode; cell: (row: T) => ReactNode; className?: string };

export function DataTable<T extends { id: string }>({ rows, columns, empty }: {
  rows: T[]; columns: Column<T>[]; empty?: ReactNode;
}) {
  if (rows.length === 0) return <>{empty}</>;
  return (
    <table className="w-full text-sm">
      <thead>
        <tr className="border-b border-surface-border text-left text-xs text-slate-500">
          {columns.map((c) => <th key={c.key} className={cn('py-2', c.className)}>{c.header}</th>)}
        </tr>
      </thead>
      <tbody>
        {rows.map((row) => (
          <tr key={row.id} className="border-b border-surface-border last:border-0">
            {columns.map((c) => <td key={c.key} className={cn('py-3', c.className)}>{c.cell(row)}</td>)}
          </tr>
        ))}
      </tbody>
    </table>
  );
}
```

The generic `T extends { id: string }` enforces the key rule in the type system — there is no place for an index key.

## Misuse list — confusable pairs

| The pair that gets confused | When each actually applies |
| --- | --- |
| `React.memo` vs `useMemo` | `memo` skips a **component** via a shallow props comparison. `useMemo` caches a **value**. Heavy list-item rendering → `memo`; a heavy computation → `useMemo` |
| `useEffect` vs computing during render | An effect is only for **synchronizing with an external system** (subscriptions, timers, DOM measurement). A value that comes out of props/state is computed during render |
| `useEffect` vs `useLayoutEffect` | Use `useLayoutEffect` only when the DOM must be measured·corrected before it is painted. Otherwise `useEffect` (a layout effect blocks paint) |
| StrictMode double invocation vs a real bug | React 18 development mode runs an effect twice, mount→unmount→mount. Writing the cleanup properly resolves it. Guarding the second run with a `useRef` is hiding the symptom |
| `key={index}` vs `key={item.id}` | An index key is allowed only in a static array that is never reordered·inserted into·deleted from. A server list always uses `id` |
| Injecting hooks into a shared component vs injecting props | The moment a shared component calls `useQuery`/`useNavigate` it belongs to one feature. Values and callbacks it needs arrive as props |
| `forwardRef` needed vs not | In React 18 a ref is not passed as a prop. A shared input·button whose DOM node has to be touched from outside requires `forwardRef` |
| Splitting components vs splitting files | Several components in one file is fine. The criterion is not the file count but the **scope of reuse** — a subcomponent nobody uses from outside stays in the same file |
