# How a duckent verb executes its compiled statement list

**Status:** decided. **Chosen mechanism: C — pragma query substitution.**
**Does it give all-or-nothing execution of a statement list? Yes — measured.**
**Cost: the invocation spelling must be `PRAGMA verb(...)`, not `CALL verb(...)`.**

Measured against DuckDB `v1.5.5` (submodule `d8cdaa33fda`), duckent-ext at `caa48a6`.

---

## The question

Seven verbs — `tree_ddl_create`, `tree_ddl_drop`, `tree_ddl_alter`, `tree_insert`,
`tree_replace`, `tree_delete`, `tree_check` — each have to run the N statements their
compile macro returns as a `VARCHAR[]`. The compile macros emit **no transaction control**
(verified: `grep -c "BEGIN TRANSACTION" src/sql_macros/03_ddl.sql src/sql_macros/04_dml.sql`
→ `0`, `0`), because a compiler that emitted `BEGIN TRANSACTION` could not be executed from
inside a query at all. That was removed deliberately in the plan repo at `a21d889`, on the
core design's §4 principle that a mutating operation is "a pure compiler plus a thin
executor".

So the executor's own execution context is the **only** thing that can provide atomicity.
Three mechanisms were plausible. This is what each actually did.

The reference behaviour is `Session.execute` in the plan repo's `test/run.py`: call the
compile macro, then run each statement inside one `BEGIN` / `COMMIT` with `ROLLBACK` on
error.

## The probe

The deciding test is the one the plan repo's own `test/sql/00_smoke.test` already uses for
this property, so this reproduces an established test rather than inventing one. The compile
macro is overridden to a two-statement list whose **second statement raises**, so the first
must leave nothing behind:

```sql
CREATE OR REPLACE MACRO tree_compile_check(sch, nm) AS
  ['CREATE TABLE ' || nm || '(x INT)', 'SELECT error(''boom'')'];
```

A mechanism is atomic if, after the verb fails with `boom`, the table does not exist.

The probe registered one verb per mechanism (`tree_check_a`, `tree_check_b`, `tree_check_c`)
over the same `tree_compile_check` macro, so all three were measured from one build.

---

## Mechanism A — table function, statements on a fresh `Connection`

A `TableFunction` whose scan opens `Connection con(*context.db)` and runs the compile query
and then each statement on it.

**Result: NOT atomic. The first statement survived.**

```
D CALL tree_check_a('main','a_roll');
Invalid Input Error: boom
D SELECT count(*) AS a_rows_left FROM a_roll;
┌─────────────┐
│ a_rows_left │
│    int64    │
├─────────────┤
│           0 │
└─────────────┘
```

`a_roll` exists with zero rows: `CREATE TABLE` committed, then `SELECT error('boom')` raised,
and nothing undid the `CREATE`. A separate `Connection` has its own `ClientContext` and its
own transaction, and in autocommit each statement commits as it completes. This is the
expected answer, now confirmed rather than assumed.

A could presumably be made atomic *within itself* by having the executor issue `BEGIN` /
`COMMIT` / `ROLLBACK` on that side connection — the Python reference's shape. That variant was
not measured, because it was rejected on reasoning rather than on a number: the work
would then commit in a transaction **unrelated to the caller's**: a verb inside the caller's
`BEGIN … ROLLBACK` would survive the caller's rollback, and the verb's writes would be
visible to other connections before the caller's statement finished. Mechanism C gets real
atomicity without that split-brain.

Note also that no in-tree DuckDB code opens a `Connection` from inside a running query. The
only three uses are database startup and WAL replay (`src/main/database.cpp:207,236`,
`src/storage/wal_replay.cpp:399`).

## Mechanism B — table function, statements through the calling `ClientContext`

A `TableFunction` whose scan calls `context.Query(sql, false)` so the statements join the
transaction the `CALL` already opened.

**Result: DuckDB does not reject this with an error. It deadlocks.**

There is no error text to quote — that is the finding. The probe file was run alone under a
timeout:

```
$ timeout 90 ./build/release/test/unittest "test/sql/93_spike_executor_b.test" \
    --test-config test/test_config.json
Terminated
EXIT=124
```

All 16 threads of the hung process were blocked on a futex, i.e. a lock, not a spin and not a
swallowed exception:

```
tid=3115727 state=S wchan=futex_do_wait
tid=3115728 state=S wchan=futex_do_wait
... (16 of 16 identical)
```

Traced to source: `ClientContext::Query(const string &, QueryParameters)`
(`src/main/client_context.cpp:1041`) takes `auto lock = LockContext();` as its first
statement. `LockContext()` returns a `ClientContextLock`
(`src/include/duckdb/main/client_context.hpp:327`), which is a plain
`std::unique_lock` over `mutex context_lock`
(`src/include/duckdb/main/client_context.hpp:318`) — not recursive. The scan is itself running
inside `ExecutePendingQueryInternal(*lock, …)`, under that same lock. Re-entering is therefore
a self-deadlock.

It deadlocks on the **compile** query, before any statement in the list runs, so B never gets
as far as the atomicity question. Every public `ClientContext` entry point that could run SQL
— `Query`, `PendingQuery`, `Prepare`, `RunFunctionInTransaction` — takes the same lock, so
there is no variant of B that reaches the caller's transaction through the public API.

**B is not viable.** It is worse than non-atomic: it hangs the session with no error.

## Mechanism C — pragma query substitution

Register the verb as a `PragmaFunction::PragmaCall(name, pragma_query_t, …)`. The handler
returns the compiled statements joined with `;`, and DuckDB parses and executes that text in
the caller's own transaction.

**Result: ATOMIC.**

```
D PRAGMA tree_check_c('main','c_roll');
Invalid Input Error: boom
D ROLLBACK;
D SELECT count(*) AS c_rows_left FROM c_roll;
Catalog Error: Table with name c_roll does not exist!
```

The success case commits normally:

```
D PRAGMA tree_check_c('main','c_ok');     -- list is CREATE TABLE + INSERT VALUES (7)
D SELECT x AS c_ok_value FROM c_ok;
┌────────────┐
│ c_ok_value │
│   int32    │
├────────────┤
│          7 │
└────────────┘
```

And the verb genuinely joins the **caller's** transaction, rather than merely having one of
its own — the caller's own concurrent work rolls back with it:

```
D BEGIN TRANSACTION;
D CREATE TABLE caller_side(y INT);
D PRAGMA tree_check_c('main','c_in_txn');
Invalid Input Error: boom
D ROLLBACK;
D SELECT count(*) FROM c_in_txn;
Catalog Error: Table with name c_in_txn does not exist!
D SELECT count(*) FROM caller_side;
Catalog Error: Table with name caller_side does not exist!
```

### Why it is atomic — the mechanism in source

`StatementPreprocessor::TryReparsePragma` (`src/planner/statement_preprocessor.cpp:107`) calls
the `pragma_query_t`, re-parses the returned text into N statements, and hands them to
`AddStatements` (`:32`). `GetTransactionHandling` (`:74`) then decides, and this is the part
that supplies the atomicity:

- caller in autocommit, N > 1 → `WRAP_IN_TRANSACTION`: DuckDB prepends a real
  `BEGIN TRANSACTION` and appends `COMMIT`, both with
  `TransactionInvalidationPolicy::ALL_ERRORS_INVALIDATE_TRANSACTION`.
- caller already in a transaction → `SET current_transaction_invalidation_policy =
  'ALL_ERRORS_INVALIDATE_TRANSACTION'` around the body, restored afterwards.

So the transaction is DuckDB's, not duckent's, and duckent emits no transaction control
anywhere — in the macros or in C++. That is exactly the division `a21d889` asked for.

`ALL_ERRORS_INVALIDATE_TRANSACTION` is stronger than the Python reference's `try/except
ROLLBACK`: it rolls back on **parse-time and bind-time** errors too, not only runtime ones.
Measured, with a deliberately malformed second statement:

```
D PRAGMA tree_check_c('main','c_roll');
Parser Error: syntax error at or near "boom"
D SELECT count(*) FROM c_roll;
Catalog Error: Table with name c_roll does not exist!
```

### Precedent

This is not a novel use of the API. `PRAGMA import_database('dir')`
(`src/function/pragma/pragma_queries.cpp:156`, registered at `:231`) is a `pragma_query_t`
that reads `schema.sql` and `load.sql` and returns their concatenated statements for DuckDB to
execute atomically. duckent's verbs are structurally identical: compile a statement list, hand
it back, let DuckDB run it.

---

## The one real cost: `CALL` does not reach a pragma function

Every one of the ~250 verb invocations in the plan repo's corpus (20 files;
`CALL tree_ddl_create` × 187, `CALL tree_ddl_alter` × 26, `CALL tree_insert` × 17,
`CALL tree_check` × 9, `CALL tree_delete` × 4, `CALL tree_ddl_drop` × 4,
`CALL tree_replace` × 3) uses the `CALL` spelling. It does not dispatch to a pragma:

```
D CALL tree_check_c('main', 'viacall');
Catalog Error: Table Function with name tree_check_c does not exist!
Did you mean "tree_check_a"?
```

This is structural, not a lookup quirk, and it cannot be worked around:

- `Transformer::TransformCall` (`src/parser/transform/statement/transform_call.cpp`)
  unconditionally produces a `CallStatement`.
- `Binder::Bind(CallStatement &)` (`src/planner/binder/statement/bind_call.cpp`) rewrites it
  into `SELECT * FROM <table_function_ref>`.
- that ref is resolved only as `CatalogType::TABLE_FUNCTION_ENTRY`
  (`src/planner/binder/tableref/bind_table_function.cpp:368`). No pragma fallback exists.
- the preprocessing stage where statement substitution and transaction wrapping happen is
  reachable only from `StatementType::PRAGMA_STATEMENT` and `StatementType::MULTI_STATEMENT`,
  and `MultiStatement` is produced only by the transformer itself (PIVOT, multi-action ALTER
  TABLE) — never by an extension.

DuckDB itself acknowledges the asymmetry: the *opposite* mistake already gets a courtesy
message, `"Pragma Function with name %s does not exist, but a table function with the same
name exists, try `CALL %s(...)`"` (`src/planner/binder/statement/bind_pragma.cpp:41`).

### Mitigation (measured, recommended for Task 5)

A `PragmaFunction` and a `TableFunction` may share a name — they are different catalog types.
Registering both, with the table function's **bind** throwing, turns the confusing
"does not exist" into an actionable instruction while leaving the working `PRAGMA` path
untouched. Measured:

```
D PRAGMA tree_check_e('main','e_ok');
D SELECT x AS e_ok_value FROM e_ok;
┌────────────┐
│ e_ok_value │
│   int32    │
├────────────┤
│          7 │
└────────────┘
D CALL tree_check_e('main','e_via_call');
Binder Error: tree_check_e must be invoked as PRAGMA tree_check_e(...), not CALL: a CALL runs
inside a query, where the compiled statement list cannot be executed atomically
```

Task 5 should register both for all seven verbs. The corpus change (`CALL` → `PRAGMA`) is
mechanical, and belongs to the plan repo; it is flagged here, not made here.

---

## Known limitation to carry into Task 5: compile reads committed state only

The `pragma_query_t` handler runs inside
`StatementPreprocessor::Preprocess` → `RunFunctionInTransactionInternal(lock, …)`, which
**already holds the context lock**. So the compile step cannot use `context.Query` either —
for the same reason mechanism B cannot — and must evaluate the compile macro on a side
`Connection`. Compiling is a pure read, so this is sound for atomicity. But the side
connection cannot see the caller's **uncommitted** state.

Measured. The caller inserts rows inside an open transaction, and the compile macro embeds
`(SELECT count(*) FROM seen)` in the name it generates:

```
D BEGIN TRANSACTION;
D INSERT INTO seen VALUES (2);
D INSERT INTO seen VALUES (3);
D SELECT count(*) AS caller_sees FROM seen;
┌─────────────┐
│ caller_sees │
│    int64    │
├─────────────┤
│           3 │
└─────────────┘
D PRAGMA tree_check_e('main','u');
D SELECT table_name AS compiled_against FROM duckdb_tables() WHERE table_name LIKE 'u\_%' ESCAPE '\';
┌──────────────────┐
│ compiled_against │
│     varchar      │
├──────────────────┤
│ u_1              │
└──────────────────┘
```

The caller sees 3; compilation saw 1. **In an explicit transaction, a verb compiles against
state as of the transaction's start, not against what the transaction has done so far.**

Consequences:

- **Autocommit — the corpus' usage — is unaffected.** Each verb is its own transaction, so
  there is no uncommitted state to miss. Execution is still fully atomic there.
- **`BEGIN; CALL tree_ddl_create(a); CALL tree_ddl_create(b, like := a); COMMIT;` would
  mis-compile**, because `b`'s compile would not see `a`'s `tree_catalog` rows. This is a
  *compile-time staleness* bug, not an atomicity bug, and it must be either documented as
  unsupported or detected and refused in Task 5.
- The same staleness applies to mechanism A's compile step, so it is not a reason to prefer A.

There is no public API that avoids it. The expression-binder route used by `Binder::BindPragma`
to evaluate pragma arguments in the caller's transaction will not serve, because
`ConstantBinder` rejects subqueries outright —
`throw BinderException(clause + " cannot contain subqueries")`
(`src/planner/expression_binder/constant_binder.cpp:25`) — and the real compile macros contain
them (e.g. `tree_compile_create` has
`EXISTS (SELECT 1 FROM tree_catalog.trees t WHERE …)`, `src/sql_macros/03_ddl.sql:119`).

---

## Decision

| | atomic? | `CALL` spelling? | viable? |
|---|---|---|---|
| A — fresh `Connection` | **no** (measured) | yes | no |
| B — calling `ClientContext` | n/a — **deadlocks** (measured) | yes | no |
| C — pragma query substitution | **yes** (measured) | no — `PRAGMA` only | **chosen** |

**Mechanism C. It gives all-or-nothing execution of the statement list**, supplied by DuckDB's
own statement preprocessor rather than by anything duckent emits, which keeps the compilers
free of transaction control exactly as `a21d889` intended. It is the only candidate that is
atomic at all, and the only one that composes correctly with a caller's own transaction.

For Task 5:

1. Register each of the seven verbs as `PragmaFunction::PragmaCall(name, handler, …)`.
2. Register a same-named `TableFunction` whose bind throws the "use PRAGMA" `BinderException`,
   so existing `CALL` sites fail legibly.
3. Compile on a side `Connection`; do **not** emit `BEGIN` / `COMMIT` anywhere.
4. Handle, or explicitly refuse, multiple verbs inside one explicit transaction — see the
   compile-staleness limitation above.
5. The corpus must move from `CALL verb(...)` to `PRAGMA verb(...)` (plan repo; ~250 sites,
   mechanical).

## Reproducing

The probe code was throwaway and is **not committed** — it registered `tree_check_a/b/c/e`,
which Task 5 replaces with the real verbs, and its atomicity assertions duplicate the
`tree_compile_check` rollback case in the plan repo's `test/sql/00_smoke.test`, which Task 6
adds. Nothing was left behind in `test/sql/`; `make test` is unchanged at 7 assertions in 2
test cases.

To reproduce: add a source registering the three shapes above, then run the two-statement
failing-list probe against each. Mechanism B must be run alone and under a timeout — it hangs.
