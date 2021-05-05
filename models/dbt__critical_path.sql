with models as (

    select *
    from {{ ref('stg_dbt__models') }}

),

latest_executions as (

    select *
    from {{ ref('fct_dbt__latest_full_model_executions') }}

),

latest_id as (
    -- Find the latest full, incremental execution

    select
        any_value(command_invocation_id) as command_invocation_id
    from latest_executions

),

latest_models as (
    -- Get the latest set of models for the above execution

    select
        models.node_id,
        models.depends_on_nodes,
        models.model_materialization
    from latest_id
    left join models on latest_id.command_invocation_id = models.command_invocation_id


),

node_dependencies as (
    -- Create a row for each model and dependency (could be another model, or source)

    select
        latest_models.node_id,
        node.value::string as depends_on_node_id,
        regexp_substr(node.value::string, '^([a-z]+)') as depends_on_node_type
    from latest_models,
    lateral flatten(input => latest_models.depends_on_nodes) as node

),

node_dependencies_deduped as (
    -- depends_on_nodes is simply a list of all the ref() statements used in a model, so it may contain duplicates

    select distinct
        node_id,
        depends_on_node_type,
        depends_on_node_id
    from node_dependencies

),

model_dependencies_with_total_node_runtime as (
    -- Model dependencies enriched with execution time

    select distinct
        node_dependencies_deduped.node_id,
        latest_executions.total_node_runtime,
        depends_on_node_id
    from node_dependencies_deduped
    left join latest_executions on node_dependencies_deduped.node_id = latest_executions.node_id
    where depends_on_node_type = 'model'

),

models_with_at_least_one_model_dependency as (
    -- Return a list of model nodes which have at least one model dependency

    select distinct
        node_id
    from node_dependencies
    where depends_on_node_type = 'model'

),

models_with_no_model_dependencies_with_total_node_runtime as (
    -- Models which have no dependencies enriched with execution time
    -- These are models at the base of the tree

    select
        latest_models.node_id,
        latest_executions.total_node_runtime
    from latest_models
    left join models_with_at_least_one_model_dependency
        on latest_models.node_id = models_with_at_least_one_model_dependency.node_id
    left join latest_executions on latest_models.node_id = latest_executions.node_id
    where models_with_at_least_one_model_dependency.node_id is null

),

models_with_dependent_models as (
    -- Get a list of all the models which have dependent models

    select distinct depends_on_node_id as node_id
    from node_dependencies_deduped

),

models_with_no_dependent_models as (
    -- Models which have no dependents
    -- These are models at the tips of the tree

    select
        latest_models.node_id
    from latest_models
    left join models_with_dependent_models
    on latest_models.node_id = models_with_dependent_models.node_id
    where models_with_dependent_models.node_id is null

),

anchor as (
    -- The anchor of a recursive CTE is the initial query
    -- The anchor in this case is models which have no dependents, the tips of the tree
    -- The dependencies for these models are joined in to build out the paths during recursion

    select
        models_with_no_dependent_models.node_id,
        coalesce(node_dependencies_deduped.depends_on_node_id, '') as depends_on_node_id,
        coalesce(latest_executions.total_node_runtime, 0) as total_node_runtime
    from models_with_no_dependent_models
    left join node_dependencies_deduped on models_with_no_dependent_models.node_id = node_dependencies_deduped.node_id
    left join latest_executions on models_with_no_dependent_models.node_id = latest_executions.node_id

),

all_needed_dependencies as (
    -- Union all the base models with all other dependencies
    -- Use an empty string for depends_on_node_id to avoid NULL result in a non-nullable column error
    -- Nothing will join onto the empty string depends_on_node_id, ending the recursion at the base.

    select
        node_id,
        total_node_runtime,
        '' as depends_on_node_id
    from models_with_no_model_dependencies_with_total_node_runtime
    union
    select
        node_id,
        total_node_runtime,
        depends_on_node_id as depends_on_node_id
    from model_dependencies_with_total_node_runtime

),

search_path (node_ids, total_time) as (
    -- The recursive part
    -- This CTE creates an array of node_ids and total_time for every possible path through the DAG
    -- Starting with the tips of the tree, work backwards through every path until there's a '' depends_on_node_id

    select
        array_construct(depends_on_node_id, node_id),
        total_node_runtime
    from anchor
    union all
    select
        array_cat(to_array(all_needed_dependencies.depends_on_node_id), search_path.node_ids) as node_ids,
        all_needed_dependencies.total_node_runtime + search_path.total_time
    from search_path
    left join all_needed_dependencies
    where get(search_path.node_ids, 0) = all_needed_dependencies.node_id

),

longest_path_node_ids as (
    -- Find the path with the longest total time

    select
        -- Remove any empty strings from the beginning of the array that were introduced in search_path to prevent infinite recursion
        case
            when get(node_ids, 0) = ''
            -- Ensure we keep the last element of the array by using array_size for the last index
            then array_slice(node_ids, 1, array_size(node_ids))
            else node_ids
        end as node_ids,
        total_time
    from search_path
    order by total_time desc
    limit 1

),

flattened as (
    -- Flatten the array of node_ids and keep the index

    select
        value as node_id,
        index
    from longest_path_node_ids,
    lateral flatten (input => node_ids)

),

longest_path_with_times as (
    -- Join the indidivual model execution times back in along with the materializations

    select
        flattened.node_id::string as node_id,
        flattened.index,
        latest_executions.total_node_runtime/60 as execution_minutes,
        latest_models.model_materialization
    from flattened
    left join latest_executions on flattened.node_id = latest_executions.node_id
    left join latest_models on flattened.node_id = latest_models.node_id

)

select * from longest_path_with_times
