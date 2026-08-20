# Fabric notebook source

# METADATA ********************

# META {
# META   "kernel_info": {
# META     "name": "synapse_pyspark"
# META   },
# META   "dependencies": {
# META     "lakehouse": {
# META       "default_lakehouse": "00000000-0000-0000-0000-0000000000br",
# META       "default_lakehouse_name": "lh_bronze",
# META       "default_lakehouse_workspace_id": "00000000-0000-0000-0000-0000000000ws"
# META     },
# META     "environment": {
# META       "environmentId": "00000000-0000-0000-0000-0000000000ev",
# META       "workspaceId": "00000000-0000-0000-0000-0000000000ws"
# META     }
# META   }
# META }

# MARKDOWN ********************

# # Ingest_Bronze
#
# Reads the daily sales extract from the landing storage account and writes it
# to the Bronze lakehouse without transformation. The storage account URL is
# rewritten per environment by `workspace/parameter.yml`.

# PARAMETERS CELL ********************

p_run_date = "1970-01-01"
p_source_container = "sales"

# METADATA ********************

# META {
# META   "language": "python",
# META   "language_group": "synapse_pyspark"
# META }

# CELL ********************

from pyspark.sql import functions as F

LANDING_ACCOUNT_URL = "https://stcontosolandingdev.dfs.core.windows.net"

source_path = f"{LANDING_ACCOUNT_URL}/{p_source_container}/dt={p_run_date}/*.parquet"
target_table = "bronze_sales_orders"

print(f"Reading {source_path}")

# METADATA ********************

# META {
# META   "language": "python",
# META   "language_group": "synapse_pyspark"
# META }

# CELL ********************

df = (
    spark.read.format("parquet")
    .load(source_path)
    .withColumn("_ingested_at_utc", F.current_timestamp())
    .withColumn("_source_file", F.input_file_name())
    .withColumn("_run_date", F.lit(p_run_date).cast("date"))
)

(
    df.write.format("delta")
    .mode("overwrite")
    .option("replaceWhere", f"_run_date = '{p_run_date}'")
    .partitionBy("_run_date")
    .saveAsTable(target_table)
)

print(f"Wrote {df.count()} rows to {target_table} for {p_run_date}")

# METADATA ********************

# META {
# META   "language": "python",
# META   "language_group": "synapse_pyspark"
# META }
