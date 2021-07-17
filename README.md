# Tails.com's dbt Artifacts Package
This package builds a mart of tables from dbt artifacts loaded into a table. It is compatible with Snowflake only. The models are based off of the [v1 schema](https://docs.getdbt.com/reference/artifacts/dbt-artifacts/#notes) introduced in dbt 0.19.0.

Models included:

- `dim_dbt__models`
- `fct_dbt__model_executions`
- `fct_dbt__latest_full_model_executions`
- `fct_dbt__critical_path`
- `fct_dbt_run_results`
- `fact_dbt__test_executions`

The critical path model determines the slowest route through your DAG, which provides you with the information needed to make a targeted effort to reducing `dbt run` times. For example:

![Critical Path](https://github.com/tailsdotcom/dbt_artifacts/raw/main/critical_path.png)

## Installation

1. Add this package to your `packages.yml` following [these instructions](https://docs.getdbt.com/docs/building-a-dbt-project/package-management/)

2. Configure the following variables in your `dbt_project.yml`:

```yml
vars:
  dbt_artifacts:
    dbt_artifacts_database: your_db # optional, default is your target database
    dbt_artifacts_schema: your_schema # optional, default is 'dbt_artifacts'
    dbt_artifacts_table: your_table # optional, default is 'artifacts'

models:
  ...
  dbt_artifacts:
    +schema: your_destination_schema
    staging:
      +schema: your_destination_schema

```
Note that the model materializations are defined in this package's `dbt_project.yml`, so do not set them in your project.

3. Run `dbt deps`.

## Generating the source table
This package requires that the source data exists in a table in Snowflake.

### Option 1: Loading local files
Snowflake makes it possible to load local files into your warehouse. We've included a number of macros to assist with this. This method can be used by both dbt Cloud users, and users of other orchestration tools.

1. To initially create these tables, execute `dbt run-operation create_artifact_resources` ([source](macros/create_artifact_resources.sql)). This will create a stage and a table named `{{ target.database }}.dbt_artifacts.artifacts` — you can override this name using the variables listed in the Installation section, above.

2. Add [operations](https://docs.getdbt.com/docs/building-a-dbt-project/hooks-operations/#operations) to your production run to load files into your table, via the `upload_artifacts` macro ([source](macros/upload_artifacts.sql)). You'll need to specify which files to upload through use of the `--args` flag. Here's an example setup.
```txt
$ dbt  seed
$ dbt  run-operation upload_dbt_artifacts --args '{filenames: [manifest, run_results]}'

$ dbt  run
$ dbt  run-operation upload_dbt_artifacts --args '{filenames: [manifest, run_results]}'

$ dbt  test
$ dbt  run-operation upload_dbt_artifacts --args '{filenames: [run_results]}'

$ dbt  source snapshot-freshness
$ dbt  run-operation upload_dbt_artifacts --args '{filenames: [sources]}'

$ dbt  docs generate
$ dbt  run-operation upload_dbt_artifacts --args '{filenames: [catalog]}'
```

### Option 2: Loading cloud-storage files

If you are using an orchestrator, you might instead upload these files to cloud storage — the method to do this will depend on your orchestrator. Then, link the cloud storage destination to a Snowflake external stage, and use a snowpipe to copy these files into the source table:

```sql
copy into ${snowflake_table.dbt_artifacts.database}.${snowflake_table.dbt_artifacts.schema}.${snowflake_table.dbt_artifacts.name}
from (
    select
    $1 as data,
    $1:metadata:generated_at::timestamp_tz as generated_at,
    metadata$filename as path,
    regexp_substr(metadata$filename, '([a-z_]+.json)$') as artifact_type
    from @${snowflake_stage.dbt_artifacts.database}.${snowflake_stage.dbt_artifacts.schema}.${snowflake_stage.dbt_artifacts.name}
)
file_format = (type = 'JSON')
```


## Usage
The models will be picked up on your next `dbt run` command. You can also run the package specifically with `dbt run -m dbt_artifacts`.

## Additional acknowledgement
The macros in this package have been adapted from code shared by [Kevin Chan](https://github.com/KevinC-wk) and [Jonathan Talmi](https://github.com/jtalmi) of [Snaptravel](snaptravel.com).

Thank you for sharing your work with the community!
