<!-- orangekit-pack: frontend/nextjs v3.12.0 -->
# TypeScript Standards

Type-writing standards that assume strict mode: no any, type guards, utility types, null handling, naming.

## 1. Core rules

- **strict mode** enabled (`tsconfig.json`)
- **No `any`** → `unknown` + a type guard, or a concrete type
- **The `@/` alias** is mandatory — no relative-path imports
- Declare components with the **`function` keyword** (no `React.FC` arrow functions)
- **The props type goes in the same file as the component** (resources/component-patterns.md)

## 2. type vs interface

```ts
// interface: component props, object shapes
interface UserCardProps {
  user: User
  className?: string
  onSelect?: (id: string) => void
}

// type: unions, utilities, simple aliases
type Status = 'active' | 'pending' | 'closed'
type Nullable<T> = T | null
```

## 3. No any — unknown plus type guards

```ts
// Bad
function processData(data: any) {/* … */}

// Good: unknown + narrowing
function processData(data: unknown) {
  if (typeof data === 'string') return data.toUpperCase()
  if (isUser(data)) return data.name
  throw new Error('Unexpected data type')
}

// An object type guard
function isUser(value: unknown): value is User {
  return typeof value === 'object' && value !== null && 'id' in value && 'email' in value
}
```

A discriminated union narrows without a guard:

```ts
type ActionResult<T> =
  | { success: true; data: T }
  | { success: false; error: string }

function handle<T>(result: ActionResult<T>) {
  if (result.success) return result.data     // narrowed to T here
  console.error(result.error)
}
```

## 4. Type imports use `import type`

```ts
import type { Metadata } from 'next'
import type { Task } from '@/lib/queries/tasks'
import type { Database } from '@/types/database'

// When mixing values and types
import { getCurrentUser } from '@/lib/auth'
import type { AuthUser } from '@/lib/auth'
```

## 5. Function return types

State the return type on a public API (query functions·Server Actions); leave components to inference.

```ts
// Query function: an explicit return type (the lib/queries/ convention)
// Data access itself is handled by the backend axis's client — this layer owns only the type boundary
export async function getTaskById(id: string): Promise<Task | null> {
  const rows = await getTasks({ id })     // the implementation is in backend-guide's data access section
  return rows[0] ?? null
}

// Server Action: pin the return contract with a type (the full definition is in resources/complete-example.md §6)
import type { ActionState } from '@/app/(main)/tasks/actions'
export async function deleteTask(id: string): Promise<ActionState> {/* … */}

// Component: omit the return type (JSX is inferred automatically)
export function TaskCard({ task }: TaskCardProps) {
  return <div>{task.title}</div>
}
```

## 6. Utility types

```ts
type UpdateTaskInput = Partial<Task>                          // all optional
type TaskSummary = Pick<Task, 'id' | 'title'>                 // only some
type CreateTaskInput = Omit<Task, 'id' | 'created_at'>        // some excluded
type StatusColors = Record<Status, string>                    // key-value map

const statusColors: StatusColors = {
  active: 'text-green-600',
  pending: 'text-yellow-600',
  closed: 'text-muted-foreground',
}
```

Do not hand-write a type again when it can be derived from an existing one.

## 7. Handling null/undefined

```tsx
const name = user?.profile?.name              // optional chaining
const displayName = user?.name ?? 'Anonymous' // nullish coalescing (unlike ||: keeps 0·'')

// Narrow with an early return — preferred over a non-null assertion (!)
function renderUser(user: User | null) {
  if (!user) return <EmptyState title="User not found." />   // defined in: component-patterns.md §5
  return <UserCard user={user} />             // user is non-null here
}
```

Use the `!` assertion only when you are truly certain (looking up a static element and the like).

## 8. Naming Conventions

| Target | Rule | Example |
| --- | --- | --- |
| Component/type/interface | PascalCase | `UserCard`, `TaskListProps` |
| Function/variable | camelCase | `formatDate`, `userName` |
| Constant | UPPER_SNAKE_CASE | `MAX_RETRIES`, `API_URL` |
| Type suffix | reflects the role | `Props`, `State`, `Input`, `Response` |
| Zustand store hook | use~Store | `useCartStore`, `useUiStore` |
| Custom hook | use~ | `useDebounce`, `useMediaQuery` |

For file naming rules (kebab-case and so on) see resources/file-organization.md.
