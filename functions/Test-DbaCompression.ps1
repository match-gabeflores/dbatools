﻿function Test-DbaCompression {
<#
	.SYNOPSIS
		Returns tables and indexes with preferred compression setting.

     .DESCRIPTION
		This function returns the results of a full table/index compression analysis.
        This function returns the best option to date for either NONE, Page, or Row Compression.
        Remember Uptime is critical, the longer uptime, the more accurate the analysis is.
        You would probably be best if you utilized Get-DbaUptime first, before running this command.
		
		Test-DbaCompression script derived from GitHub and the tigertoolbox 
        (https://github.com/Microsoft/tigertoolbox/tree/master/Evaluate-Compression-Gains)
        In the output, you will find the following information:

        Column Percent_Update shows the percentage of update operations on a specific table, index, or partition, 
        relative to total operations on that object. The lower the percentage of Updates 
        (that is, the table, index, or partition is infrequently updated), the better candidate it is for page compression.

        Column Percent_Scan shows the percentage of scan operations on a table, index, or partition, relative to total 
        operations on that object. The higher the value of Scan (that is, the table, index, or partition is mostly scanned), 
        the better candidate it is for page compression.

        Column Compression_Type_Recommendation can have four possible outputs indicating where there is most gain, 
        if any: ‘PAGE’, ‘ROW’, ‘NO_GAIN’ or ‘?’. When the output is ‘?’ this approach could not give a recommendation, 
        so as a rule of thumb I would lean to ROW if the object suffers mainly UPDATES, or PAGE if mainly INSERTS, 
        but this is where knowing your workload is essential. When the output is ‘NO_GAIN’ well, that means that according 
        to sp_estimate_data_compression_savings no space gains will be attained when compressing, as in the above output example, 
        where compressing would grow the affected object.
        
        Note: Note that this script will execute on the context of the current database. 
        Also be aware that this may take awhile to execute on large objects, because if the IS locks taken by the 
        sp_estimate_data_compression_savings cannot be honored, the SP will be blocked.
	
	.PARAMETER SqlInstance
		SQL Server name or SMO object representing the SQL Server to connect to. This can be a collection and receive pipeline input to allow the function to be executed against multiple SQL Server instances.
	
	.PARAMETER SqlCredential
		SqlCredential object to connect as. If not specified, current Windows login will be used.
	
	.PARAMETER Database
		The database(s) to process - this list is autopopulated from the server. If unspecified, all databases will be processed.
	
	.PARAMETER ExcludeDatabase
		The database(s) to exclude - this list is autopopulated from the server
	
	.PARAMETER Silent
		Replaces user friendly yellow warnings with bloody red exceptions of doom!
		Use this if you want the function to throw terminating errors you want to catch.
	
	.NOTES
		Author: Jason Squires (@js_0505, jstexasdba@gmail.com)
		Tags: Compression, Table, Database
		Website: https://dbatools.io
		Copyright: (C) Chrissy LeMaire, clemaire@gmail.com
		License: GNU GPL v3 https://opensource.org/licenses/GPL-3.0
	
	.LINK
		https://dbatools.io/Test-DbaCompression
	
	.EXAMPLE
		Test-DbaCompression -SqlInstance localhost
		
		Returns all user database files and free space information for the local host
	
	.EXAMPLE
		Test-DbaCompression -SqlInstance ServerA -Database DBName | Out-GridView
		Returns results of all potential compression options for a single database 
        with the recommendation of either Page or Row into and nicely formated GridView
	
	.EXAMPLE
		Test-DbaCompression -SqlInstance ServerA 
		Returns results of all potential compression options for all databases
        with the recommendation of either Page or Row

    .EXAMPLE
        $cred = Get-Credential sqladmin		
        Test-DbaCompression -SqlInstance ServerA -ExcludeDatabase Database -SqlCredential $cred
		Returns results of all potential compression options for all databases
        with the recommendation of either Page or Row
	
    .EXAMPLE
        $servers = 'Server1','Server2'
        foreach ($svr in $servers)
        {
			Test-DbaCompression -SqlInstance $svr | Export-Csv -Path C:\temp\CompressionAnalysisPAC.csv -Append
        }
	
	    This produces a full analysis of all your servers listed and is pushed to a csv for you to 
        analyize.

#>
	[CmdletBinding(DefaultParameterSetName = "Default")]
	param (
        [parameter(Mandatory = $true, ValueFromPipeline = $true)]
		[Alias("ServerInstance", "SqlServer")]
		[DbaInstanceParameter[]]
		$SqlInstance,
		
		[PSCredential]
		$SqlCredential,
		
        [object[]]
        $Database,
		
		[object[]]
		$ExcludeDatabase,
		
		[switch]
		$Silent
	)
	
	begin {
		Write-Message -Level System -Message "Bound parameters: $($PSBoundParameters.Keys -join ", ")"
		$sql = "SET NOCOUNT ON;
                
                IF OBJECT_ID('tempdb..##testdbacompression' , 'U') IS NOT NULL
                DROP TABLE ##testdbacompression
				
                IF OBJECT_ID('tempdb..##tmpEstimateRow' , 'U') IS NOT NULL
                DROP TABLE ##tmpEstimateRow

                IF OBJECT_ID('tempdb..##tmpEstimatePage' , 'U') IS NOT NULL
                DROP TABLE ##tmpEstimatePage

                CREATE TABLE ##testdbacompression ([Schema] sysname
					,[TableName] sysname
					,[IndexName] sysname NULL
					,[Partition] int
					,[IndexID] int
					,[IndexType] VARCHAR(12)
					,[PercentScan] smallint
					,[PercentUpdate] smallint
					,[RowEstimatePercentOriginal] bigint
					,[PageEstimatePercentOriginal] bigint
					,[CompressionTypeRecommendation] VARCHAR(7)
					,SizeCurrent bigint
					,SizeRequested bigint
					,PercentCompression numeric(10,2)
				);

				CREATE TABLE ##tmpEstimateRow (
					objname sysname
					,schname sysname
					,indid int
					,partnr int
					,SizeCurrent bigint
					,SizeRequested bigint
					,SampleCurrent bigint
					,SampleRequested bigint
				);

				CREATE TABLE ##tmpEstimatePage (
					objname sysname
					,schname sysname
					,indid int
					,partnr int
					,SizeCurrent bigint
					,SizeRequested bigint
					,SampleCurrent bigint
					,SampleRequested bigint
				);

				INSERT INTO ##testdbacompression 
				([Schema]
				,[TableName]
				,[IndexName]
				,[Partition]
				,[IndexID]
				,[IndexType]
				,[PercentScan]
				,[PercentUpdate]
				)
				SELECT s.name AS [Schema], o.name AS [TableName], x.name AS [IndexName],
				       i.partition_number AS [Partition], i.Index_ID AS [IndexID], x.type_desc AS [IndexType],
				       i.range_scan_count * 100.0 / (i.range_scan_count + i.leaf_insert_count + i.leaf_delete_count + i.leaf_update_count + i.leaf_page_merge_count + i.singleton_lookup_count) AS [PercentScan],
				       i.leaf_update_count * 100.0 / (i.range_scan_count + i.leaf_insert_count + i.leaf_delete_count + i.leaf_update_count + i.leaf_page_merge_count + i.singleton_lookup_count) AS [PercentUpdate]
				FROM sys.dm_db_index_operational_stats (db_id(), NULL, NULL, NULL) i
					INNER JOIN sys.objects o ON o.object_id = i.object_id
					INNER JOIN sys.schemas s ON o.schema_id = s.schema_id
					INNER JOIN sys.indexes x ON x.object_id = i.object_id AND x.Index_ID = i.Index_ID
					INNER JOIN sys.partitions p on x.object_id = p.object_id and x.Index_ID = p.Index_ID
				WHERE (i.range_scan_count + i.leaf_insert_count + i.leaf_delete_count + leaf_update_count + i.leaf_page_merge_count + i.singleton_lookup_count) <> 0
					AND objectproperty(i.object_id,'IsUserTable') = 1 and p.data_compression_desc = 'NONE' and p.rows>0
				ORDER BY [TableName] ASC;

				DECLARE @schema sysname, @tbname sysname, @ixid int
				DECLARE cur CURSOR FAST_FORWARD FOR SELECT [Schema], [TableName], [IndexID] FROM ##testdbacompression
				OPEN cur
				FETCH NEXT FROM cur INTO @schema, @tbname, @ixid
				WHILE @@FETCH_STATUS = 0
				BEGIN
					DECLARE @sqlcmd NVARCHAR(500)
					SET @sqlcmd = 'EXEC sp_estimate_data_compression_savings ''' + @schema + ''', ''' + @tbname + ''', ''' + cast(@ixid as varchar)+ ''', NULL, ''ROW''';
					INSERT INTO ##tmpEstimateRow
					(objname 
					,schname 
					,indid 
					,partnr 
					,SizeCurrent 
					,SizeRequested 
					,SampleCurrent 
					,SampleRequested 
					)
                    EXECUTE sp_executesql @sqlcmd
                    
                    SET @sqlcmd = 'EXEC sp_estimate_data_compression_savings ''' + @schema + ''', ''' + @tbname + ''', ''' + cast(@ixid as varchar)+ ''', NULL, ''PAGE''';
					INSERT INTO ##tmpEstimatePage
					(objname 
					,schname 
					,indid 
					,partnr 
					,SizeCurrent 
					,SizeRequested 
					,SampleCurrent 
					,SampleRequested 
					)
                    EXECUTE sp_executesql @sqlcmd

                    FETCH NEXT FROM cur INTO @schema, @tbname, @ixid
				
                END
				CLOSE cur
				DEALLOCATE cur;

				WITH tmp_cte (objname, schname, indid, pct_of_orig_row, pct_of_orig_page, SizeCurrent,SizeRequested) 
				     AS (SELECT tr.objname, 
				                tr.schname, 
				                tr.indid, 
				                ( tr.SampleRequested * 100 ) / CASE 
				                                            WHEN tr.SampleCurrent = 0 THEN 1 
				                                            ELSE tr.SampleCurrent 
				                                          END AS pct_of_orig_row, 
				                ( tp.SampleRequested * 100 ) / CASE 
				                                            WHEN tp.SampleCurrent = 0 THEN 1 
				                                            ELSE tp.SampleCurrent 
				                                          END AS pct_of_orig_page,
								tr.SizeCurrent,
								tr.SizeRequested
				         FROM   ##tmpestimaterow tr 
				                INNER JOIN ##tmpestimatepage tp 
				                        ON tr.objname = tp.objname 
				                           AND tr.schname = tp.schname 
				                           AND tr.indid = tp.indid 
				                           AND tr.partnr = tp.partnr) 
				UPDATE ##testdbacompression 
				SET    [RowEstimatePercentOriginal] = tcte.pct_of_orig_row, 
				       [PageEstimatePercentOriginal] = tcte.pct_of_orig_page,
					   SizeCurrent=tcte.SizeCurrent,
					   SizeRequested=tcte.SizeRequested
				FROM   tmp_cte tcte, 
				       ##testdbacompression tcomp 
				WHERE  tcte.objname = tcomp.TableName 
				       AND tcte.schname = tcomp.[schema] 
				       AND tcte.indid = tcomp.IndexID; 

				WITH tmp_cte2 (TableName, [schema], IndexID, [CompressionTypeRecommendation] 
				     ) 
				     AS (SELECT TableName, 
				                [schema], 
				                IndexID, 
				                CASE 
				                  WHEN [RowEstimatePercentOriginal] >= 100 
				                       AND [PageEstimatePercentOriginal] >= 100 THEN 'NO_GAIN' 
				                  WHEN [PercentUpdate] >= 10 THEN 'ROW' 
				                  WHEN [PercentScan] <= 1 
				                       AND [PercentUpdate] <= 1 
				                       AND [RowEstimatePercentOriginal] < 
				                           [PageEstimatePercentOriginal] 
				                THEN 
				                  'ROW' 
				                  WHEN [PercentScan] <= 1 
				                       AND [PercentUpdate] <= 1 
				                       AND [RowEstimatePercentOriginal] > 
				                           [PageEstimatePercentOriginal] 
				                THEN 
				                  'PAGE' 
				                  WHEN [PercentScan] >= 60 
				                       AND [PercentUpdate] <= 5 THEN 'PAGE' 
				                  WHEN [PercentScan] <= 35 
				                       AND [PercentUpdate] <= 5 THEN '?' 
				                  ELSE 'ROW' 
				                END 
				         FROM   ##testdbacompression) 

				UPDATE ##testdbacompression 
				SET    [CompressionTypeRecommendation] = 
				       tcte2.[CompressionTypeRecommendation]
				FROM   tmp_cte2 tcte2, 
				       ##testdbacompression tcomp2 
				WHERE  tcte2.TableName = tcomp2.TableName 
				       AND tcte2.[schema] = tcomp2.[schema] 
				       AND tcte2.IndexID = tcomp2.IndexID; 
				
				UPDATE ##testdbacompression
				set PercentCompression = 100 -(cast([SizeRequested] as numeric(10,2)) * 100/([SizeCurrent]-ABS(SIGN([SizeCurrent]))+1)) 
				from ##testdbacompression 

				SET NOCOUNT ON;
				DECLARE @UpTime VARCHAR(12), @StartDate DATETIME, @sqlmajorver int,  @params NVARCHAR(500)
				SELECT @sqlmajorver = CONVERT(int, (@@microsoftversion / 0x1000000) & 0xff);

				IF @sqlmajorver = 9
				BEGIN
					SET @sqlcmd = N'SELECT @StartDateOUT = login_time, @UpTimeOUT = DATEDIFF(mi, login_time, GETDATE()) FROM master..sysprocesses WHERE spid = 1';
				END
				ELSE
				BEGIN
					SET @sqlcmd = N'SELECT @StartDateOUT = sqlserver_start_time, @UpTimeOUT = DATEDIFF(mi,sqlserver_start_time,GETDATE()) FROM sys.dm_os_sys_info';
				END

				SET @params = N'@StartDateOUT DATETIME OUTPUT, @UpTimeOUT VARCHAR(12) OUTPUT';

				EXECUTE sp_executesql @sqlcmd, @params, @StartDateOUT=@StartDate OUTPUT, @UpTimeOUT=@UpTime OUTPUT;

				SELECT 
				DBName = DB_Name()
				,[Schema] 
				,[TableName] 
				,[IndexName] 
				,[Partition] 
				,[IndexID] 
				,[IndexType] 
				,[PercentScan] 
				,[PercentUpdate] 
				,[RowEstimatePercentOriginal] 
				,[PageEstimatePercentOriginal]
				,[CompressionTypeRecommendation] 
				,SizeCurrentKB = [SizeCurrent]
				,SizeRequestedKB = [SizeRequested]
                ,PercentCompression
				FROM ##testdbacompression;

				IF OBJECT_ID('tempdb..##setdbacompression' , 'U') IS NOT NULL
                DROP TABLE ##testdbacompression
				
                IF OBJECT_ID('tempdb..##tmpEstimateRow' , 'U') IS NOT NULL
                DROP TABLE ##tmpEstimateRow

                IF OBJECT_ID('tempdb..##tmpEstimatePage' , 'U') IS NOT NULL
                DROP TABLE ##tmpEstimatePage;"
	}
	
	process {
		
		foreach ($instance in $SqlInstance) {
			try {
				Write-Message -Level VeryVerbose -Message "Connecting to $instance" -Target $instance
				$server = Connect-SqlInstance -SqlInstance $instance -SqlCredential $SourceSqlCredential -MinimumVersion 10
			}
			catch {
				Stop-Function -Message "Failed to process Instance $Instance" -ErrorRecord $_ -Target $instance -Continue
			}
			
            $Server.ConnectionContext.StatementTimeout = 0
                
            #The reason why we do this is beause of SQL 2016 and they now allow for compression on standard edition.
                if ($Server.EngineEdition -eq 'Standard' -and $Server.VersionMajor -lt '13')
                    {
                    Stop-Function -Message "Only SQL Server Enterprise Edition supports compression on $Server" -Target $Server -Continue
                    }
			#If IncludeSystemDBs is true, include systemdbs
			#look at all databases, online/offline/accessible/inaccessible and tell user if a db can't be queried.
			try {
				$dbs = $server.Databases
                if ($Database) {
					$dbs = $dbs | Where-Object { $Database -contains $_.Name -and $_.IsAccessible -and $_.IsSystemObject -EQ 0 }
				}
				
				else {
					$dbs = $dbs | Where-Object { $_.IsAccessible -and $_.IsSystemObject -EQ 0 }
				}
				
				if (Test-Bound "ExcludeDatabase") {
					$dbs = $dbs | Where-Object Name -NotIn $ExcludeDatabase
				}
			}
			catch {
				Stop-Function -Message "Unable to gather list of databases for $instance" -Target $instance -ErrorRecord $_ -Continue
			}
			

			foreach ($db in $dbs) {
				try {
                    Write-Message -Level Verbose -Message "Querying $instance - $db"
                    if ($db.status -ne 'Normal' -or $db.IsAccessible -eq $false) 
                        {
						Write-Message -Level Warning -Message "$db is not accessible." -Target $db
                         
						continue
					    }
                    if ($db.CompatibilityLevel -lt 'Version100')
                        { 
                          Stop-Function -Message "$db has a compatibility level lower than Version100 and will be skipped." -Target $db -Continue 
                        }
                    #Execute query against individual database and add to output
                    foreach ($row in ($server.Query($sql, $db.Name)))
                        {
						[pscustomobject]@{
							ComputerName = $server.NetName
							InstanceName = $server.ServiceName
							SqlInstance = $server.DomainInstanceName
							Database = $row.DBName
							Schema = $row.Schema
							TableName = $row.TableName
							IndexName = $row.IndexName
							Partition = $row.Partition
							IndexID = $row.IndexID
							IndexType = $row.IndexType
							PercentScan = $row.PercentScan
							PercentUpdate = $row.PercentUpdate
							RowEstimatePercentOriginal = $row.RowEstimatePercentOriginal
							PageEstimatePercentOriginal = $row.PageEstimatePercentOriginal
							CompressionTypeRecommendation = $row.CompressionTypeRecommendation
							SizeCurrentKB = $row.SizeCurrentKB
							SizeRequestedKB = $row.SizeRequestedKB
                            PercentCompression = $row.PercentCompression
						                  }
				        }
				    }
				catch {
					Stop-Function -Message "Unable to query $instance - $db" -Target $db -ErrorRecord $_ -Continue
				}
			}
		}
	}
}