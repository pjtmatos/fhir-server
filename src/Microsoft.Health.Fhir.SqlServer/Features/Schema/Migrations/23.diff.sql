/*************************************************************
    This migration removes the existing primary key clustered index and adds a clustered index on Id column in the ResourceChangeData table.
    The migration is "online" meaning the server is fully available during the upgrade, but it can be very time-consuming.
    For reference, a resource change data table with 10 million records took around 25 minutes to complete 
    on the Azure SQL database (SQL elastic pools - GeneralPurpose: Gen5, 2 vCores).
**************************************************************/

EXEC dbo.LogSchemaMigrationProgress 'Beginning migration to version 23.';
GO

EXEC dbo.LogSchemaMigrationProgress 'Adding or updating FetchResourceChanges_3 stored procedure.';
GO

--
-- STORED PROCEDURE
--     FetchResourceChanges_3
--
-- DESCRIPTION
--     Returns the number of resource change records from startId. The start id is inclusive.
--
-- PARAMETERS
--     @startId
--         * The start id of resource change records to fetch.
--     @lastProcessedDateTime
--         * The last checkpoint datetime.
--     @pageSize
--         * The page size for fetching resource change records.
--
-- RETURN VALUE
--     Resource change data rows.
--
CREATE OR ALTER PROCEDURE dbo.FetchResourceChanges_3
    @startId bigint,
    @lastProcessedDateTime datetime2(7),
    @pageSize smallint
AS
BEGIN

    SET NOCOUNT ON;

    DECLARE @partitions TABLE (partitionBoundary datetime2(7));
    DECLARE @precedingPartitionBoundary datetime2(7) = (SELECT TOP(1) CAST(prv.value as datetime2(7)) AS value FROM sys.partition_range_values AS prv
                                                           INNER JOIN sys.partition_functions AS pf ON pf.function_id = prv.function_id
                                                       WHERE pf.name = N'PartitionFunction_ResourceChangeData_Timestamp'
                                                           AND CAST(prv.value AS datetime2(7)) < DATEADD(HOUR, DATEDIFF(HOUR, 0, @lastProcessedDateTime), 0)
                                                       ORDER BY prv.boundary_id DESC);

    IF (@precedingPartitionBoundary IS NULL) BEGIN
        SET @precedingPartitionBoundary = CONVERT(datetime2(7), N'1970-01-01T00:00:00.0000000');
    END;

    INSERT INTO @partitions 
        SELECT CAST(prv.value AS datetime2(7)) FROM sys.partition_range_values AS prv
            INNER JOIN sys.partition_functions AS pf ON pf.function_id = prv.function_id
        WHERE pf.name = N'PartitionFunction_ResourceChangeData_Timestamp'
              AND CAST(prv.value AS datetime2(7)) >= DATEADD(HOUR, DATEDIFF(HOUR, 0, @precedingPartitionBoundary), 0)
              AND CAST(prv.value AS datetime2(7)) < DATEADD(HOUR, 1, SYSUTCDATETIME());

    /* Given the fact that Read Committed Snapshot isolation level is enabled on the FHIR database, 
       using the Repeatable Read isolation level table hint to avoid skipping resource changes 
       due to interleaved transactions on the resource change data table.
       In Repeatable Read, the select query execution will be blocked until other open transactions are completed
       for rows that match the search condition of the select statement. 
       A write transaction (update/delete) on the rows that match 
       the search condition of the select statement will wait until the current transaction is completed. 
       Other transactions can insert new rows that match the search conditions of statements issued by the current transaction.
       But, other transactions will be blocked to insert new rows during the execution of the select query, 
       and wait until the execution completes. */	  
    SELECT TOP(@pageSize) Id,
      Timestamp,
      ResourceId,
      ResourceTypeId,
      ResourceVersion,
      ResourceChangeTypeId
    FROM @partitions AS p CROSS APPLY (
        SELECT TOP(@pageSize) Id,
          Timestamp,
          ResourceId,
          ResourceTypeId,
          ResourceVersion,
          ResourceChangeTypeId
        FROM dbo.ResourceChangeData WITH (REPEATABLEREAD)
            WHERE Id >= @startId AND $PARTITION.PartitionFunction_ResourceChangeData_Timestamp(Timestamp) = $PARTITION.PartitionFunction_ResourceChangeData_Timestamp(p.partitionBoundary)
        ORDER BY Id ASC
        ) AS rcd
    ORDER BY rcd.Id ASC;
END;
GO

EXEC dbo.LogSchemaMigrationProgress 'Deleting PK_ResourceChangeData_TimestampId index from ResourceChangeData table.';
GO

IF EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'PK_ResourceChangeData_TimestampId')
BEGIN
    /* Drops PK_ResourceChangeData_TimestampId index. "ONLINE = ON" indicates long-term table locks aren't held for the duration of the index operation. 
       During the main phase of the index operation, only an Intent Share (IS) lock is held on the source table. 
       This behavior enables queries or updates to the underlying table and indexes to continue. */
    ALTER TABLE dbo.ResourceChangeData DROP CONSTRAINT PK_ResourceChangeData_TimestampId WITH(ONLINE = ON);
END;
GO

EXEC dbo.LogSchemaMigrationProgress 'Deleting PK_ResourceChangeDataStaging_TimestampId index from ResourceChangeDataStaging table.';
GO

IF EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'PK_ResourceChangeDataStaging_TimestampId')
BEGIN
    /* Drops PK_ResourceChangeDataStaging_TimestampId index. "ONLINE = ON" indicates long-term table locks aren't held for the duration of the index operation. 
       During the main phase of the index operation, only an Intent Share (IS) lock is held on the source table. 
       This behavior enables queries or updates to the underlying table and indexes to continue. */
    ALTER TABLE dbo.ResourceChangeDataStaging DROP CONSTRAINT PK_ResourceChangeDataStaging_TimestampId WITH(ONLINE = ON);
END;
GO

EXEC dbo.LogSchemaMigrationProgress 'Creating IXC_ResourceChangeData index on ResourceChangeData table.';
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IXC_ResourceChangeData')
BEGIN
    /* Adds a clustered index on ResourceChangeData table. "ONLINE = ON" indicates long-term table locks aren't held for the duration of the index operation. 
       During the main phase of the index operation, only an Intent Share (IS) lock is held on the source table. 
       This behavior enables queries or updates to the underlying table and indexes to continue. */
    CREATE CLUSTERED INDEX IXC_ResourceChangeData ON dbo.ResourceChangeData
        (Id ASC) WITH(ONLINE = ON) ON PartitionScheme_ResourceChangeData_Timestamp(Timestamp);
END;
GO

EXEC dbo.LogSchemaMigrationProgress 'Creating IXC_ResourceChangeDataStaging index on ResourceChangeDataStaging table.';
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IXC_ResourceChangeDataStaging')
BEGIN
    /* Adds a clustered index on ResourceChangeDataStaging table. "ONLINE = ON" indicates long-term table locks aren't held for the duration of the index operation. 
       During the main phase of the index operation, only an Intent Share (IS) lock is held on the source table. 
       This behavior enables queries or updates to the underlying table and indexes to continue. */
    CREATE CLUSTERED INDEX IXC_ResourceChangeDataStaging ON dbo.ResourceChangeDataStaging
        (Id ASC, Timestamp ASC) WITH(ONLINE = ON) ON [PRIMARY];
END;
GO

EXEC dbo.LogSchemaMigrationProgress 'Completed migration to version 23.';
GO
