# Fabric notebook source

# METADATA ********************

# META {
# META   "kernel_info": {
# META     "name": "synapse_pyspark"
# META   },
# META   "dependencies": {
# META     "lakehouse": {
# META       "default_lakehouse": "00000000-0000-0000-0000-0000000000gd",
# META       "default_lakehouse_name": "lh_gold",
# META       "default_lakehouse_workspace_id": "00000000-0000-0000-0000-0000000000ws"
# META     },
# META     "environment": {
# META       "environmentId": "00000000-0000-0000-0000-0000000000ev",
# META       "workspaceId": "00000000-0000-0000-0000-0000000000ws"
# META     }
# META   }
# META }

# MARKDOWN ********************

# # Transform_Gold
#
# Reads from the Bronze lakehouse by ABFS path (Bronze is not the default
# lakehouse for this notebook) and writes the curated fact table to Gold.

# PARAMETERS CELL ********************

p_run_date = "1970-01-01"

# METADATA ********************

# META {
# META   "language": "python",
# META   "language_group": "synapse_pyspark"
# META }

# CELL ********************

from pyspark.sql import functions as F

BRONZE_TABLES = (
    "abfss://00000000-0000-0000-0000-0000000000ws@onelake.dfs.fabric.microsoft.com/"
    "00000000-0000-0000-0000-0000000000br/Tables"
)

bronze = spark.read.format("delta").load(f"{BRONZE_TABLES}/bronze_sales_orders")

# METADATA ********************

# META {
# META   "language": "python",
# META   "language_group": "synapse_pyspark"
# META }

# CELL ********************

fact_sales = (
    bronze.filter(F.col("_run_date") == F.lit(p_run_date))
    .filter(F.col("order_id").isNotNull())
    .select(
        F.col("order_id").cast("string").alias("OrderId"),
        F.col("customer_id").cast("string").alias("CustomerId"),
        F.col("product_id").cast("string").alias("ProductId"),
        F.to_date("order_date").alias("OrderDate"),
        F.col("quantity").cast("int").alias("Quantity"),
        F.col("unit_price").cast("decimal(18,2)").alias("UnitPrice"),
        (F.col("quantity") * F.col("unit_price")).cast("decimal(18,2)").alias("SalesAmount"),
    )
    .dropDuplicates(["OrderId"])
)

(
    fact_sales.write.format("delta")
    .mode("overwrite")
    .option("replaceWhere", f"OrderDate = '{p_run_date}'")
    .option("mergeSchema", "false")
    .saveAsTable("fact_sales")
)

print(f"Curated {fact_sales.count()} rows into fact_sales for {p_run_date}")

# METADATA ********************

# META {
# META   "language": "python",
# META   "language_group": "synapse_pyspark"
# META }

# CELL ********************

spark.sql("OPTIMIZE fact_sales VORDER")

# METADATA ********************

# META {
# META   "language": "python",
# META   "language_group": "synapse_pyspark"
# META }
