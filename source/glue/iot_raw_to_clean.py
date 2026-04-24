import sys
from awsglue.transforms import *
from awsglue.utils import getResolvedOptions
from pyspark.context import SparkContext
from awsglue.context import GlueContext
from awsglue.job import Job
from awsgluedq.transforms import EvaluateDataQuality

args = getResolvedOptions(sys.argv, [
    'JOB_NAME',
    'database_name',
    'table_name',
    'output_path'
])
sc = SparkContext()
glueContext = GlueContext(sc)
spark = glueContext.spark_session
job = Job(glueContext)
job.init(args['JOB_NAME'], args)

# Default ruleset used by all target nodes with data quality enabled
DEFAULT_DATA_QUALITY_RULESET = """
    Rules = [
        ColumnCount > 0
    ]
"""

# Script generated for node AWS Glue Data Catalog
AWSGlueDataCatalog_node1776994683844 = glueContext.create_dynamic_frame.from_catalog(
    database=args['database_name'],
    table_name=args['table_name'],
    transformation_ctx="AWSGlueDataCatalog_node1776994683844"
)

# Script generated for node Change Schema
ChangeSchema_node1776994710958 = ApplyMapping.apply(
    frame=AWSGlueDataCatalog_node1776994683844,
    mappings=[
        ("timestamp", "string", "timestamp", "timestamp"),
        ("trip_id", "string", "trip_id", "string"),
        ("vin", "string", "vin", "string"),
        ("brake", "int", "brake", "float"),
        ("steeringwheelangle", "int", "steeringwheelangle", "float"),
        ("torqueattransmission", "double", "torqueattransmission", "float"),
        ("enginespeed", "double", "enginespeed", "float"),
        ("vehiclespeed", "double", "vehiclespeed", "float"),
        ("acceleration", "double", "acceleration", "float"),
        ("parkingbrakestatus", "boolean", "parkingbrakestatus", "boolean"),
        ("brakepedalstatus", "boolean", "brakepedalstatus", "boolean"),
        ("transmissiongearposition", "string", "transmissiongearposition", "string"),
        ("gearleverposition", "string", "gearleverposition", "string"),
        ("odometer", "double", "odometer", "float"),
        ("ignitionstatus", "string", "ignitionstatus", "string"),
        ("fuellevel", "double", "fuellevel", "float"),
        ("fuelconsumedsincerestart", "double", "fuelconsumedsincerestart", "float"),
        ("oiltemp", "double", "oiltemp", "float"),
        ("location.latitude", "double", "location.latitude", "double"),
        ("location.longitude", "double", "location.longitude", "double"),
        ("partition_0", "string", "year", "string"),
        ("partition_1", "string", "month", "string"),
        ("partition_2", "string", "day", "string"),
        ("partition_3", "string", "hour", "string")
    ],
    transformation_ctx="ChangeSchema_node1776994710958"
)

# Script generated for node Amazon S3
EvaluateDataQuality().process_rows(
    frame=ChangeSchema_node1776994710958,
    ruleset=DEFAULT_DATA_QUALITY_RULESET,
    publishing_options={
        "dataQualityEvaluationContext": "EvaluateDataQuality_node1776994671256",
        "enableDataQualityResultsPublishing": True
    },
    additional_options={
        "dataQualityResultsPublishing.strategy": "BEST_EFFORT",
        "observations.scope": "ALL"
    }
)

AmazonS3_node1776994733312 = glueContext.write_dynamic_frame.from_options(
    frame=ChangeSchema_node1776994710958,
    connection_type="s3",
    format="glueparquet",
    connection_options={
        "path": args['output_path'],
        "partitionKeys": []
    },
    format_options={"compression": "snappy"},
    transformation_ctx="AmazonS3_node1776994733312"
)

job.commit()
