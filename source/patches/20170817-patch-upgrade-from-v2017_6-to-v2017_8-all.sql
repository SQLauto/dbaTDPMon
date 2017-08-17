USE [dbaTDPMon]
GO

RAISERROR('*-----------------------------------------------------------------------------*', 10, 1) WITH NOWAIT
RAISERROR('* dbaTDPMon (Troubleshoot Database Performance / Monitoring)                  *', 10, 1) WITH NOWAIT
RAISERROR('* https://github.com/rentadba/dbaTDPMon, under GNU (GPLv3) licence model      *', 10, 1) WITH NOWAIT
RAISERROR('*-----------------------------------------------------------------------------*', 10, 1) WITH NOWAIT
RAISERROR('* Patch script: from version 2017.6 to 2017.8 (2017.08.17)				  *', 10, 1) WITH NOWAIT
RAISERROR('*-----------------------------------------------------------------------------*', 10, 1) WITH NOWAIT

SELECT * FROM [dbo].[appConfigurations] WHERE [module] = 'common' AND [name] = 'Application Version'
GO
UPDATE [dbo].[appConfigurations] SET [value] = N'2017.08.17' WHERE [module] = 'common' AND [name] = 'Application Version'
GO


/*---------------------------------------------------------------------------------------------------------------------*/
/* patch module: maintenance-plan																							   */
/*---------------------------------------------------------------------------------------------------------------------*/
RAISERROR('Patching module: MAINTENANCE-PLAN', 10, 1) WITH NOWAIT

RAISERROR('Create procedure: [dbo].[usp_mpDatabaseBackup]', 10, 1) WITH NOWAIT
GO
IF  EXISTS (
	    SELECT * 
	      FROM sysobjects 
	     WHERE [id] = OBJECT_ID(N'[dbo].[usp_mpDatabaseBackup]') 
	       AND type in (N'P', N'PC'))
DROP PROCEDURE [dbo].[usp_mpDatabaseBackup]
GO

-----------------------------------------------------------------------------------------
CREATE PROCEDURE [dbo].[usp_mpDatabaseBackup]
		@sqlServerName		[sysname] = @@SERVERNAME,
		@dbName				[sysname],
		@backupLocation		[nvarchar](1024)=NULL,	/*  disk only: local or UNC */
		@flgActions			[smallint] = 1,			/*  1 - perform full database backup
														2 - perform differential database backup
														4 - perform transaction log backup
													*/
		@flgOptions			[int] = 5083,		/*  1 - use CHECKSUM (default)
													2 - use COMPRESSION, if available (default)
													4 - use COPY_ONLY
													8 - force change backup type (default): if log is set, and no database backup is found, a database backup will be first triggered
												  										    if diff is set, and no full database backup is found, a full database backup will be first triggered
												   16 - verify backup file (default)
											       32 - Stop execution if an error occurs. Default behaviour is to print error messages and continue execution
												   64 - create folders for each database (default)
												  128 - when performing cleanup, delete also orphans diff and log backups, when cleanup full database backups(default)
												  256 - for +2k5 versions, use xp_delete_file option (default)
												  512 - skip databases involved in log shipping (primary or secondary or logs, secondary for full/diff backups) (default)
												 1024 - on alwayson availability groups, for secondary replicas, force copy-only backups (default)
												 2048 - change retention policy from RetentionDays to RetentionBackupsCount (number of full database backups to be kept)
													  - this may be forced by setting to true property 'Change retention policy from RetentionDays to RetentionBackupsCount'
												 4096 - use xp_dirtree to identify orphan backup files to be deleted, when using option 128 (default)
												*/
		@retentionDays		[smallint]	= NULL,
		@executionLevel		[tinyint]	=  0,
		@debugMode			[bit]		=  0
/* WITH ENCRYPTION */
AS

-- ============================================================================
-- Copyright (c) 2004-2015 Dan Andrei STEFAN (danandrei.stefan@gmail.com)
-- ============================================================================
-- Author			 : Dan Andrei STEFAN
-- Create date		 : 2004-2006 / review on 2015.03.04
-- Module			 : Database Maintenance Plan 
-- Description		 : Optimization and Maintenance Checks
-- ============================================================================

------------------------------------------------------------------------------------------------------------------------------------------
--returns: 0 = success, >0 = failure

DECLARE		@queryToRun  					[nvarchar](2048),
			@queryParameters				[nvarchar](512),
			@nestedExecutionLevel			[tinyint]

DECLARE		@backupFileName					[nvarchar](1024),
			@backupFilePath					[nvarchar](1024),
			@backupType						[nvarchar](8),
			@backupOptions					[nvarchar](256),
			@optionBackupWithChecksum		[bit],
			@optionBackupWithCompression	[bit],
			@optionBackupWithCopyOnly		[bit],
			@optionForceChangeBackupType	[bit],
			@serverEdition					[sysname],
			@serverVersionStr				[sysname],
			@serverVersionNum				[numeric](9,6),
			@errorCode						[int],
			@currentDate					[datetime],
			@databaseStatus					[int],
			@databaseStateDesc				[sysname]

DECLARE		@backupStartDate				[datetime],
			@backupDurationSec				[int],
			@backupSizeBytes				[bigint],
			@eventData						[varchar](8000),
			@maxPATHLength					[smallint]=259

-----------------------------------------------------------------------------------------
SET NOCOUNT ON

-----------------------------------------------------------------------------------------
IF object_id('#serverPropertyConfig') IS NOT NULL DROP TABLE #serverPropertyConfig
CREATE TABLE #serverPropertyConfig
			(
				[value]			[sysname]	NULL
			)

-----------------------------------------------------------------------------------------
EXEC [dbo].[usp_logPrintMessage] @customMessage = '<separator-line>', @raiseErrorAsPrint = 1, @messagRootLevel = @executionLevel, @messageTreelevel = 0, @stopExecution=0
SET @queryToRun= 'Backup database: ' + ' [' + @dbName + ']'
EXEC [dbo].[usp_logPrintMessage] @customMessage = @queryToRun, @raiseErrorAsPrint = 0, @messagRootLevel = @executionLevel, @messageTreelevel = 0, @stopExecution=0

-----------------------------------------------------------------------------------------
--get default backup location
IF @backupLocation IS NULL
	begin
		SELECT	@backupLocation = [value]
		FROM	[dbo].[appConfigurations]
		WHERE	[name] = N'Default backup location'
				AND [module] = 'maintenance-plan'

		IF @backupLocation IS NULL
			begin
				SET @queryToRun= 'ERROR: @backupLocation parameter value not set'
				EXEC [dbo].[usp_logPrintMessage] @customMessage = @queryToRun, @raiseErrorAsPrint = 1, @messagRootLevel = @executionLevel, @messageTreelevel = 0, @stopExecution=1
			end
	end

-----------------------------------------------------------------------------------------
--get default backup retention
IF @retentionDays IS NULL
	begin
		SELECT	@retentionDays = [value]
		FROM	[dbo].[appConfigurations]
		WHERE	[name] = N'Default backup retention (days)'
				AND [module] = 'maintenance-plan'

		IF @retentionDays IS NULL
			begin
				SET @queryToRun= 'WARNING: @retentionDays parameter value not set'
				EXEC [dbo].[usp_logPrintMessage] @customMessage = @queryToRun, @raiseErrorAsPrint = 0, @messagRootLevel = @executionLevel, @messageTreelevel = 0, @stopExecution=0
			end
	end

-----------------------------------------------------------------------------------------
--get destination server running version/edition
EXEC [dbo].[usp_getSQLServerVersion]	@sqlServerName		= @sqlServerName,
										@serverEdition		= @serverEdition OUT,
										@serverVersionStr	= @serverVersionStr OUT,
										@serverVersionNum	= @serverVersionNum OUT,
										@executionLevel		= @executionLevel,
										@debugMode			= @debugMode

SET @nestedExecutionLevel = @executionLevel + 1

--------------------------------------------------------------------------------------------------
--treat exceptions
IF @dbName='master'
	begin
		SET @optionForceChangeBackupType=0
		SET @flgActions=1 /* only full backup is allowed for master database */
	end

--------------------------------------------------------------------------------------------------
--selected backup type
SELECT @backupType = CASE WHEN @flgActions & 1 = 1 THEN N'full'
						  WHEN @flgActions & 2 = 2 THEN N'diff'
						  WHEN @flgActions & 4 = 4 THEN N'log'
					 END

--------------------------------------------------------------------------------------------------
--get database status
IF @serverVersionNum >= 9
	begin
		SET @queryToRun = N'SELECT CONVERT([sysname], DATABASEPROPERTYEX(''' + @dbName + N''', ''Status'')) AS [state]' 
		SET @queryToRun = [dbo].[ufn_formatSQLQueryForLinkedServer](@sqlServerName, @queryToRun)
		IF @debugMode=1	EXEC [dbo].[usp_logPrintMessage] @customMessage = @queryToRun, @raiseErrorAsPrint = 0, @messagRootLevel = @executionLevel, @messageTreelevel = 1, @stopExecution=0

		DELETE FROM #serverPropertyConfig
		INSERT	INTO #serverPropertyConfig([value])
				EXEC (@queryToRun)

		SELECT @databaseStateDesc = [value]
		FROM #serverPropertyConfig

		SET @databaseStateDesc = ISNULL(@databaseStateDesc, 'NULL')

		/* check for the standby property */
		IF  @databaseStateDesc IN ('ONLINE')
			begin
				SET @queryToRun = N'SELECT CONVERT([sysname], DATABASEPROPERTYEX(''' + @dbName + N''', ''IsInStandBy'')) AS [state]' 
				SET @queryToRun = [dbo].[ufn_formatSQLQueryForLinkedServer](@sqlServerName, @queryToRun)
				IF @debugMode=1	EXEC [dbo].[usp_logPrintMessage] @customMessage = @queryToRun, @raiseErrorAsPrint = 0, @messagRootLevel = @executionLevel, @messageTreelevel = 1, @stopExecution=0

				DELETE FROM #serverPropertyConfig
				INSERT	INTO #serverPropertyConfig([value])
						EXEC (@queryToRun)

				IF (SELECT [value] FROM #serverPropertyConfig) = '1'
					SET @databaseStateDesc = 'STANDBY'
			end

	end
ELSE
	begin
		SET @queryToRun = N'SELECT [status] FROM master.dbo.sysdatabases WHERE [name]=''' + @dbName + N'''' 
		SET @queryToRun = [dbo].[ufn_formatSQLQueryForLinkedServer](@sqlServerName, @queryToRun)
		IF @debugMode=1	EXEC [dbo].[usp_logPrintMessage] @customMessage = @queryToRun, @raiseErrorAsPrint = 0, @messagRootLevel = @executionLevel, @messageTreelevel = 1, @stopExecution=0

		DELETE FROM #serverPropertyConfig
		INSERT	INTO #serverPropertyConfig([value])
				EXEC (@queryToRun)

		SELECT @databaseStatus = [value]
		FROM #serverPropertyConfig

		SET @databaseStateDesc =   CASE	WHEN @databaseStatus & 32 = 32			 THEN 'LOADING'
										WHEN @databaseStatus & 64 = 64			 THEN 'PRE RECOVERY'
										WHEN @databaseStatus & 128 = 128		 THEN 'RECOVERING'
										WHEN @databaseStatus & 256 = 256		 THEN 'NOT RECOVERED'
										WHEN @databaseStatus & 512 = 512		 THEN 'OFFLINE'
										WHEN @databaseStatus & 2048 = 2048		 THEN 'DBO USE ONLY'
										WHEN @databaseStatus & 4096 = 4096		 THEN 'SINGLE USER'
										WHEN @databaseStatus & 32768 = 32768	 THEN 'EMERGENCY MODE'
										WHEN @databaseStatus & 2097152 = 2097152 THEN 'STANDBY'
										WHEN @databaseStatus & 4194584 = 4194584 THEN 'SUSPECT'
										WHEN @databaseStatus = 0				 THEN 'UNKNOWN'
										ELSE 'ONLINE'
									END
	end

IF  @databaseStateDesc NOT IN ('ONLINE')
begin
	SET @queryToRun='Current database state (' + @databaseStateDesc + ') does not allow backup.'
	EXEC [dbo].[usp_logPrintMessage] @customMessage = @queryToRun, @raiseErrorAsPrint = 0, @messagRootLevel = @executionLevel, @messageTreelevel = 1, @stopExecution=0

	SET @eventData='<skipaction><detail>' + 
						'<name>database backup</name>' + 
						'<type>' + @backupType + '</type>' + 
						'<affected_object>' + @dbName + '</affected_object>' + 
						'<date>' + CONVERT([varchar](24), GETDATE(), 121) + '</date>' + 
						'<reason>' + @queryToRun + '</reason>' + 
					'</detail></skipaction>'

	EXEC [dbo].[usp_logEventMessage]	@sqlServerName	= @sqlServerName,
										@dbName			= @dbName,
										@module			= 'dbo.usp_mpDatabaseBackup',
										@eventName		= 'database backup',
										@eventMessage	= @eventData,
										@eventType		= 0 /* info */

	RETURN 0
end


--------------------------------------------------------------------------------------------------
--skip databases involved in log shipping (primary or secondary or logs, secondary for full/diff backups)
IF @flgOptions & 512 = 512
	begin
		--for full and diff backups
		IF @flgActions IN (1, 2)
			begin
				IF @serverVersionNum >= 9			
					SET @queryToRun = N'SELECT	[secondary_database]
										FROM	msdb.dbo.log_shipping_monitor_secondary
										WHERE	[secondary_server]=@@SERVERNAME
												AND [secondary_database] = ''' + @dbName + N''''
				ELSE 
					SET @queryToRun = N'SELECT	[secondary_database_name]
										FROM	msdb.dbo.log_shipping_secondaries
										WHERE	[secondary_server_name]=@@SERVERNAME
												AND [secondary_database_name] = ''' + @dbName + N''''
			end

		--for log backups
		IF @flgActions=4
			begin
				IF @serverVersionNum >= 9			
					SET @queryToRun = N'SELECT	[primary_database]
										FROM	msdb.dbo.log_shipping_monitor_primary
										WHERE	[primary_server]=@@SERVERNAME
												AND [primary_database] = ''' + @dbName + N'''
										UNION ALL
										SELECT	[secondary_database]
										FROM	msdb.dbo.log_shipping_monitor_secondary
										WHERE	[secondary_server]=@@SERVERNAME
												AND [secondary_database] = ''' + @dbName + N''''
				ELSE 
					SET @queryToRun = N'SELECT	[primary_database_name]
										FROM	msdb.dbo.log_shipping_primaries
										WHERE	[primary_server_name]=@@SERVERNAME
												AND [primary_database_name] = ''' + @dbName + N'''
										UNION ALL
										SELECT	[secondary_database_name]
										FROM	msdb.dbo.log_shipping_secondaries
										WHERE	[secondary_server_name]=@@SERVERNAME
												AND [secondary_database_name] = ''' + @dbName + N''''
			end

		SET @queryToRun = [dbo].[ufn_formatSQLQueryForLinkedServer](@sqlServerName, @queryToRun)
		IF @debugMode=1	EXEC [dbo].[usp_logPrintMessage] @customMessage = @queryToRun, @raiseErrorAsPrint = 0, @messagRootLevel = @executionLevel, @messageTreelevel = 1, @stopExecution=0

		DELETE FROM #serverPropertyConfig
		INSERT	INTO #serverPropertyConfig([value])
				EXEC (@queryToRun)

		IF (SELECT COUNT(*) FROM #serverPropertyConfig)>0
			begin
				SET @queryToRun='Log Shipping: '
				IF @flgActions IN (1, 2)
					SET @queryToRun = @queryToRun + 'Cannot perform a full or differential backup on a secondary database.'
				IF @flgActions IN (4)
					SET @queryToRun = @queryToRun + 'Cannot perform a transaction log backup since it may break the log shipping chain.'

				EXEC [dbo].[usp_logPrintMessage] @customMessage = @queryToRun, @raiseErrorAsPrint = 0, @messagRootLevel = @executionLevel, @messageTreelevel = 1, @stopExecution=0

				SET @eventData='<skipaction><detail>' + 
									'<name>database backup</name>' + 
									'<type>' + @backupType + '</type>' + 
									'<affected_object>' + @dbName + '</affected_object>' + 
									'<date>' + CONVERT([varchar](24), GETDATE(), 121) + '</date>' + 
									'<reason>' + @queryToRun + '</reason>' + 
								'</detail></skipaction>'

				EXEC [dbo].[usp_logEventMessage]	@sqlServerName	= @sqlServerName,
													@dbName			= @dbName,
													@module			= 'dbo.usp_mpDatabaseBackup',
													@eventName		= 'database backup',
													@eventMessage	= @eventData,
													@eventType		= 0 /* info */

				RETURN 0
			end
	end

--------------------------------------------------------------------------------------------------
/* AlwaysOn Availability Groups */
DECLARE @agName				[sysname],
		@agInstanceRoleDesc	[sysname],
		@agStopLimit		[int]

SET @agStopLimit = 0
IF @serverVersionNum >= 11
	EXEC @agStopLimit = [dbo].[usp_mpCheckAvailabilityGroupLimitations]	@sqlServerName		= @sqlServerName,
																		@dbName				= @dbName,
																		@actionName			= 'database backup',
																		@actionType			= @backupType,
																		@flgActions			= @flgActions,
																		@flgOptions			= @flgOptions OUTPUT,
																		@agName				= @agName OUTPUT,
																		@agInstanceRoleDesc = @agInstanceRoleDesc OUTPUT,
																		@executionLevel		= @executionLevel,
																		@debugMode			= @debugMode

IF @agStopLimit <> 0
	RETURN 0
																				
--------------------------------------------------------------------------------------------------
--check recovery model for database. transaction log backup is allowed only for FULL
--if force option is selected, for SIMPLE recovery model, backup type will be changed to diff
--------------------------------------------------------------------------------------------------
IF @flgActions & 4 = 4
	begin
		SET @queryToRun = N''
		SET @queryToRun = @queryToRun + 'SELECT CAST(DATABASEPROPERTYEX(''' + @dbName + N''', ''Recovery'') AS [sysname])'
		SET @queryToRun = [dbo].[ufn_formatSQLQueryForLinkedServer](@sqlServerName, @queryToRun)
		IF @debugMode=1	EXEC [dbo].[usp_logPrintMessage] @customMessage = @queryToRun, @raiseErrorAsPrint = 0, @messagRootLevel = @executionLevel, @messageTreelevel = 1, @stopExecution=0

		DELETE FROM #serverPropertyConfig
		INSERT	INTO #serverPropertyConfig([value])
				EXEC (@queryToRun)

		IF (SELECT UPPER([value]) FROM #serverPropertyConfig) = 'SIMPLE'
			begin
				SET @queryToRun = 'Database recovery model is SIMPLE. Transaction log backup cannot be performed.'
				EXEC [dbo].[usp_logPrintMessage] @customMessage = @queryToRun, @raiseErrorAsPrint = 0, @messagRootLevel = @executionLevel, @messageTreelevel = 1, @stopExecution=0

				SET @eventData='<skipaction><detail>' + 
									'<name>database backup</name>' + 
									'<type>' + @backupType + '</type>' + 
									'<affected_object>' + @dbName + '</affected_object>' + 
									'<date>' + CONVERT([varchar](24), GETDATE(), 121) + '</date>' + 
									'<reason>' + @queryToRun + '</reason>' + 
								'</detail></skipaction>'

				EXEC [dbo].[usp_logEventMessage]	@sqlServerName	= @sqlServerName,
													@dbName			= @dbName,
													@module			= 'dbo.usp_mpDatabaseBackup',
													@eventName		= 'database backup',
													@eventMessage	= @eventData,
													@eventType		= 0 /* info */

				RETURN 0
			end
	end
	
--------------------------------------------------------------------------------------------------
--create destination path: <@backupLocation>\@sqlServerName\@dbName
IF RIGHT(@backupLocation, 1)<>'\' SET @backupLocation = @backupLocation + N'\'
IF @agName IS NULL
	SET @backupLocation = @backupLocation + REPLACE(@sqlServerName, '\', '$') + '\' + CASE WHEN @flgOptions & 64 = 64 THEN @dbName + '\' ELSE '' END
ELSE
	SET @backupLocation = @backupLocation + REPLACE(@agName, '\', '$') + '\' + CASE WHEN @flgOptions & 64 = 64 THEN @dbName + '\' ELSE '' END

--check for maximum length of the file path
--https://msdn.microsoft.com/en-us/library/windows/desktop/aa365247(v=vs.85).aspx
print @backupLocation
print LEN(@backupLocation)
IF LEN(@backupLocation) >= @maxPATHLength
	begin
		SET @eventData='<alert><detail>' + 
							'<severity>critical</severity>' + 
							'<instance_name>' + @sqlServerName + '</instance_name>' + 
							'<name>database backup</name>' + 
							'<type>' + @backupType + '</type>' + 
							'<affected_object>' + @dbName + '</affected_object>' + 
							'<reason>Msg 3057, Level 16: The length of the device name provided exceeds supported limit (maximum length is:' + CAST(@maxPATHLength AS [nvarchar]) + ')</reason>' + 
							'<path>' + @backupLocation + '</path>' + 
							'<event_date_utc>' + CONVERT([varchar](24), GETDATE(), 121) + '</event_date_utc>' + 
						'</detail></alert>'

		EXEC [dbo].[usp_logEventMessageAndSendEmail]	@projectCode			= NULL,
														@sqlServerName			= @sqlServerName,
														@dbName					= @dbName,
														@objectName				= 'critical',
														@childObjectName		= 'dbo.usp_mpDatabaseBackup',
														@module					= 'maintenance-plan',
														@eventName				= 'database backup',
														@parameters				= NULL,	
														@eventMessage			= @eventData,
														@dbMailProfileName		= NULL,
														@recipientsList			= NULL,
														@eventType				= 6,	/* 6 - alert-custom */
														@additionalOption		= 0

		SET @errorCode = -1
	end
ELSE
	begin
		SET @queryToRun = N'EXEC [' + DB_NAME() + '].[dbo].[usp_createFolderOnDisk]	@sqlServerName	= ''' + @sqlServerName + N''',
																					@folderName		= ''' + @backupLocation + N''',
																					@executionLevel	= ' + CAST(@nestedExecutionLevel AS [nvarchar]) + N',
																					@debugMode		= ' + CAST(@debugMode AS [nvarchar]) 

		EXEC @errorCode = [dbo].[usp_sqlExecuteAndLog]	@sqlServerName	= @@SERVERNAME,
														@dbName			= NULL,
														@module			= 'dbo.usp_mpDatabaseBackup',
														@eventName		= 'create folder on disk',
														@queryToRun  	= @queryToRun,
														@flgOptions		= @flgOptions,
														@executionLevel	= @nestedExecutionLevel,
														@debugMode		= @debugMode
	end

IF @errorCode<>0 
	begin
		RETURN @errorCode
	end

--------------------------------------------------------------------------------------------------
--check if CHECKSUM backup option may apply
SET @optionBackupWithChecksum=0
IF @flgOptions & 1 = 1 AND @serverVersionNum >= 9
	SET @optionBackupWithChecksum=1

--check COMPRESSION backup option may apply
SET @optionBackupWithCompression=0
IF @flgOptions & 2 = 2 AND @serverVersionNum >= 10
	begin
		IF @serverVersionNum>=10 AND @serverVersionNum<10.5 AND (CHARINDEX('Enterprise', @serverEdition)>0 OR CHARINDEX('Developer', @serverEdition)>0)
			SET @optionBackupWithCompression=1
		
		IF @serverVersionNum>=10.5 AND (CHARINDEX('Enterprise', @serverEdition)>0 OR CHARINDEX('Developer', @serverEdition)>0 OR CHARINDEX('Standard', @serverEdition)>0)
			SET @optionBackupWithCompression=1
	end

--check COPY_ONLY backup option may apply
SET @optionBackupWithCopyOnly=0
IF @flgOptions & 4 = 4 AND @serverVersionNum >= 9
	SET @optionBackupWithCopyOnly=1

--check if another backup is needed (full) / partially applicable to AlwaysOn Availability Groups
SET @optionForceChangeBackupType=0
IF @flgOptions & 8 = 8 AND 	(@agName IS NULL OR (@agName IS NOT NULL AND @agInstanceRoleDesc = 'PRIMARY'))
	begin
		--check for any full database backup (when differential should be made) or any full/incremental database backup (when transaction log should be made)
		IF @flgActions & 2 = 2 OR @flgActions & 4 = 4
			begin
				SET @queryToRun = N''
				SET @queryToRun = @queryToRun + 'SELECT	[differential_base_lsn] FROM sys.master_files WHERE [database_id] = DB_ID(''' + @dbName + N''') AND [type] = 0 AND [file_id] = 1'
				SET @queryToRun = [dbo].[ufn_formatSQLQueryForLinkedServer](@sqlServerName, @queryToRun)
				IF @debugMode=1	EXEC [dbo].[usp_logPrintMessage] @customMessage = @queryToRun, @raiseErrorAsPrint = 0, @messagRootLevel = @executionLevel, @messageTreelevel = 1, @stopExecution=0

				DELETE FROM #serverPropertyConfig
				INSERT	INTO #serverPropertyConfig([value])
						EXEC (@queryToRun)

				DECLARE @differentialBaseLSN	[numeric](25,0)

				SELECT @differentialBaseLSN = [value] FROM #serverPropertyConfig
				
				IF @differentialBaseLSN IS NULL
					begin
						SET @optionForceChangeBackupType=1 
						SET @queryToRun = 'WARNING: Specified backup type cannot be performed since no full database backup exists. A full database backup will be taken before the requested backup type.'
						EXEC [dbo].[usp_logPrintMessage] @customMessage = @queryToRun, @raiseErrorAsPrint = 0, @messagRootLevel = @executionLevel, @messageTreelevel = 1, @stopExecution=0
					end
				ELSE	
					begin
						SET @queryToRun = N''
						SET @queryToRun = @queryToRun + 'SELECT COUNT(*) 
														FROM msdb.dbo.backupset bs
														INNER JOIN msdb.dbo.backupmediafamily bmf ON bmf.[media_set_id] = bs.[media_set_id]
														WHERE bs.[server_name] = N''' + @sqlServerName + ''' 
															AND bs.[database_name]=''' + @dbName + N''' 
															AND bs.[type] IN (''D''' + CASE WHEN @flgActions & 4 = 4 THEN N', ''I''' ELSE N'' END + N')
															AND ' + CAST(@differentialBaseLSN AS [nvarchar]) + N' BETWEEN bs.[first_lsn] AND bs.[last_lsn]
															AND bmf.[device_type] <> 7 /* virtual device */'
						IF @serverVersionNum >= 9
							SET @queryToRun = @queryToRun + N' AND [is_copy_only]=0'
						SET @queryToRun = [dbo].[ufn_formatSQLQueryForLinkedServer](@sqlServerName, @queryToRun)
						IF @debugMode=1	EXEC [dbo].[usp_logPrintMessage] @customMessage = @queryToRun, @raiseErrorAsPrint = 0, @messagRootLevel = @executionLevel, @messageTreelevel = 1, @stopExecution=0

						DELETE FROM #serverPropertyConfig
						INSERT	INTO #serverPropertyConfig([value])
								EXEC (@queryToRun)

						IF (SELECT [value] FROM #serverPropertyConfig) = 0
							begin
								SET @queryToRun = 'WARNING: Specified backup type cannot be performed since no full database backup exists. A full database backup will be taken before the requested backup type.'
								EXEC [dbo].[usp_logPrintMessage] @customMessage = @queryToRun, @raiseErrorAsPrint = 0, @messagRootLevel = @executionLevel, @messageTreelevel = 1, @stopExecution=0

								SET @optionForceChangeBackupType=1 
							end
						/*
						ELSE
							begin
								--check database differentialBaseLSN in its header (if not set, the existing full backup is not usefull)
								IF object_id('#differentialBaseLSN') IS NOT NULL DROP TABLE #differentialBaseLSN
								CREATE TABLE #differentialBaseLSN
								(
									[Value]					[varchar](255)			NULL
								)

								IF @sqlServerName <> @@SERVERNAME
									begin
										IF @serverVersionNum < 11
											SET @queryToRun = N'SELECT MAX([VALUE]) AS [Value]
																FROM OPENQUERY([' + @sqlServerName + N'], ''SET FMTONLY OFF; EXEC(''''DBCC DBINFO ([' + @dbName + N']) WITH TABLERESULTS'''')'')x
																WHERE [Object]=''differentialBaseLSN'' AND [Field]=''m_blockOffset'''
										ELSE
											SET @queryToRun = N'SELECT MAX([VALUE]) AS [Value]
																FROM OPENQUERY([' + @sqlServerName + N'], ''SET FMTONLY OFF; EXEC(''''DBCC DBINFO ([' + @dbName + N']) WITH TABLERESULTS'''') WITH RESULT SETS(([ParentObject] [nvarchar](max), [Object] [nvarchar](max), [Field] [nvarchar](max), [VALUE] [nvarchar](max))) '')x
																WHERE [Field]=''differentialBaseLSN'''
									end
								ELSE
									begin	
										IF object_id('#dbccDBINFO') IS NOT NULL DROP TABLE #dbccDBINFO
										CREATE TABLE #dbccDBINFO
											(
												[id]				[int] IDENTITY(1,1),
												[ParentObject]		[varchar](255),
												[Object]			[varchar](255),
												[Field]				[varchar](255),
												[Value]				[varchar](255)
											)

										SET @queryToRun=N'INSERT INTO #dbccDBINFO EXEC (''DBCC DBINFO (''''' + @dbName + N''''') WITH TABLERESULTS'')'

										IF @serverVersionNum >= 9
											begin
												SET @queryToRun=N'BEGIN TRY 
																	' + @queryToRun + ' 
																	END TRY 
																	BEGIN CATCH 
																		PRINT ERROR_MESSAGE() 
																	END CATCH'
											end
								
										IF @debugMode=1	EXEC [dbo].[usp_logPrintMessage] @customMessage = @queryToRun, @raiseErrorAsPrint = 0, @messagRootLevel = @executionLevel, @messageTreelevel = 1, @stopExecution=0
										EXEC sp_executesql @queryToRun

										IF @serverVersionNum < 11
											SET @queryToRun = N'SELECT MAX([Value]) AS [Value] FROM #dbccDBINFO WHERE [Object]=''dbi_differentialBaseLSN'' AND [Field]=''m_blockOffset'''											
										ELSE
											SET @queryToRun = N'SELECT MAX([Value]) AS [Value] FROM #dbccDBINFO WHERE [Field]=''dbi_differentialBaseLSN'''
									end

								IF @debugMode = 1 PRINT @queryToRun
				
								TRUNCATE TABLE #differentialBaseLSN
								SET @queryToRun=N'INSERT INTO #differentialBaseLSN([Value]) EXEC (''' + REPLACE(@queryToRun, '''', '''''') + ''')'

								IF @serverVersionNum >=9
									begin
										SET @queryToRun=N'BEGIN TRY 
															' + @queryToRun + ' 
															END TRY 
															BEGIN CATCH 
																PRINT ERROR_MESSAGE() 
															END CATCH'
									end

								IF @debugMode=1	EXEC [dbo].[usp_logPrintMessage] @customMessage = @queryToRun, @raiseErrorAsPrint = 0, @messagRootLevel = @executionLevel, @messageTreelevel = 1, @stopExecution=0
								EXEC sp_executesql @queryToRun

								IF ISNULL((SELECT [Value] FROM #differentialBaseLSN), '0') IN ('0', '0:0:0 (0x00000000:00000000:0000)')
									begin
										SET @queryToRun = 'WARNING: Specified backup type cannot be performed since no VALID full database backup exists. A full database backup will be taken before the requested backup type.'
										EXEC [dbo].[usp_logPrintMessage] @customMessage = @queryToRun, @raiseErrorAsPrint = 0, @messagRootLevel = @executionLevel, @messageTreelevel = 1, @stopExecution=0

										SET @optionForceChangeBackupType=1 
									end
							end
						*/
					end
			end			
	end

--------------------------------------------------------------------------------------------------
--compiling backup options
SET @backupOptions=N''

IF @optionBackupWithChecksum=1
	SET @backupOptions = @backupOptions + N', CHECKSUM'
IF @optionBackupWithCompression=1
	SET @backupOptions = @backupOptions + N', COMPRESSION'
IF @optionBackupWithCopyOnly=1
	SET @backupOptions = @backupOptions + N', COPY_ONLY'
IF ISNULL(@retentionDays, 0) <> 0
	SET @backupOptions = @backupOptions + N', RETAINDAYS=' + CAST(@retentionDays AS [nvarchar](32))

--------------------------------------------------------------------------------------------------
--run a full database backup, in order to perform an additional diff or log backup
IF @optionForceChangeBackupType=1
	begin
		SET @currentDate = GETDATE()
		
		IF @agName IS NULL
			SET @backupFileName = dbo.[ufn_mpBackupBuildFileName](@sqlServerName, @dbName, 'full', @currentDate)
		ELSE
			SET @backupFileName = dbo.[ufn_mpBackupBuildFileName](@agName, @dbName, 'full', @currentDate)

		--check for maximum length of the file path
		--https://msdn.microsoft.com/en-us/library/windows/desktop/aa365247(v=vs.85).aspx
		IF LEN(@backupLocation + @backupFileName) > @maxPATHLength
			begin
				SET @eventData='<alert><detail>' + 
									'<severity>critical</severity>' + 
									'<instance_name>' + @sqlServerName + '</instance_name>' + 
									'<name>database backup</name>' + 
									'<type>' + @backupType + '</type>' + 
									'<affected_object>' + @dbName + '</affected_object>' + 
									'<reason>Msg 3057, Level 16: The length of the device name provided exceeds supported limit (maximum length is:' + CAST(@maxPATHLength AS [nvarchar]) + ')</reason>' + 
									'<path>' + @backupLocation + @backupFileName + '</path>' + 
									'<event_date_utc>' + CONVERT([varchar](24), GETDATE(), 121) + '</event_date_utc>' + 
								'</detail></alert>'

				EXEC [dbo].[usp_logEventMessageAndSendEmail]	@projectCode			= NULL,
																@sqlServerName			= @sqlServerName,
																@dbName					= @dbName,
																@objectName				= 'critical',
																@childObjectName		= 'dbo.usp_mpDatabaseBackup',
																@module					= 'maintenance-plan',
																@eventName				= 'database backup',
																@parameters				= NULL,	
																@eventMessage			= @eventData,
																@dbMailProfileName		= NULL,
																@recipientsList			= NULL,
																@eventType				= 6,	/* 6 - alert-custom */
																@additionalOption		= 0

				SET @errorCode = -1
			end
		ELSE
			begin
				SET @queryToRun	= N'BACKUP DATABASE ['+ @dbName + N'] TO DISK = ''' + @backupLocation + @backupFileName + N''' WITH STATS = 10, NAME = ''' + @backupFileName + N'''' + @backupOptions
				EXEC [dbo].[usp_logPrintMessage] @customMessage = @queryToRun, @raiseErrorAsPrint = 1, @messagRootLevel = @executionLevel, @messageTreelevel = 1, @stopExecution=0

				EXEC @errorCode = [dbo].[usp_sqlExecuteAndLog]	@sqlServerName	= @sqlServerName,
																@dbName			= @dbName,
																@module			= 'dbo.usp_mpDatabaseBackup',
																@eventName		= 'database backup',
																@queryToRun  	= @queryToRun,
																@flgOptions		= @flgOptions,
																@executionLevel	= @nestedExecutionLevel,
																@debugMode		= @debugMode
			end
	end

--------------------------------------------------------------------------------------------------
SET @currentDate = GETDATE()
IF @agName IS NULL
	SET @backupFileName = dbo.[ufn_mpBackupBuildFileName](@sqlServerName, @dbName, @backupType, @currentDate)
ELSE
	SET @backupFileName = dbo.[ufn_mpBackupBuildFileName](@agName, @dbName, @backupType, @currentDate)

IF @flgActions & 1 = 1 
	begin
		SET @queryToRun	= N'BACKUP DATABASE ['+ @dbName + N'] TO DISK = ''' + @backupLocation + @backupFileName + N''' WITH STATS = 10, NAME = ''' + @backupFileName + N'''' + @backupOptions
	end

IF @flgActions & 2 = 2
	begin
		SET @queryToRun	= N'BACKUP DATABASE ['+ @dbName + N'] TO DISK = ''' + @backupLocation + @backupFileName + N''' WITH DIFFERENTIAL, STATS = 10, NAME=''' + @backupFileName + N'''' + @backupOptions
	end

IF @flgActions & 4 = 4
	begin
		SET @queryToRun	= N'BACKUP LOG ['+ @dbName + N'] TO DISK = ''' + @backupLocation + @backupFileName + N''' WITH STATS = 10, NAME=''' + @backupFileName + N'''' + @backupOptions
	end

--check for maximum length of the file path
--https://msdn.microsoft.com/en-us/library/windows/desktop/aa365247(v=vs.85).aspx
IF LEN(@backupLocation + @backupFileName) > @maxPATHLength
	begin
		SET @eventData='<alert><detail>' + 
							'<severity>critical</severity>' + 
							'<instance_name>' + @sqlServerName + '</instance_name>' + 
							'<name>database backup</name>' + 
							'<type>' + @backupType + '</type>' + 
							'<affected_object>' + @dbName + '</affected_object>' + 
							'<reason>Msg 3057, Level 16: The length of the device name provided exceeds supported limit (maximum length is:' + CAST(@maxPATHLength AS [nvarchar]) + ')</reason>' + 
							'<path>' + @backupLocation + @backupFileName + '</path>' + 
							'<event_date_utc>' + CONVERT([varchar](24), GETDATE(), 121) + '</event_date_utc>' + 
						'</detail></alert>'

		EXEC [dbo].[usp_logEventMessageAndSendEmail]	@projectCode			= NULL,
														@sqlServerName			= @sqlServerName,
														@dbName					= @dbName,
														@objectName				= 'critical',
														@childObjectName		= 'dbo.usp_mpDatabaseBackup',
														@module					= 'maintenance-plan',
														@eventName				= 'database backup',
														@parameters				= NULL,	
														@eventMessage			= @eventData,
														@dbMailProfileName		= NULL,
														@recipientsList			= NULL,
														@eventType				= 6,	/* 6 - alert-custom */
														@additionalOption		= 0
		
		SET @errorCode = -1
	end
ELSE
	begin
		EXEC [dbo].[usp_logPrintMessage] @customMessage = @queryToRun, @raiseErrorAsPrint = 1, @messagRootLevel = @executionLevel, @messageTreelevel = 1, @stopExecution=0	
		EXEC @errorCode = [dbo].[usp_sqlExecuteAndLog]	@sqlServerName	= @sqlServerName,
														@dbName			= @dbName,
														@module			= 'dbo.usp_mpDatabaseBackup',
														@eventName		= 'database backup',
														@queryToRun  	= @queryToRun,
														@flgOptions		= @flgOptions,
														@executionLevel	= @nestedExecutionLevel,
														@debugMode		= @debugMode
	end

IF @errorCode=0
	begin
		SET @queryToRun = '	SELECT TOP 1  bs.[backup_start_date]
										, DATEDIFF(ss, bs.[backup_start_date], bs.[backup_finish_date]) AS [backup_duration_sec]
										, ' + CASE WHEN @optionBackupWithCompression=1 THEN 'bs.[compressed_backup_size]' ELSE 'bs.[backup_size]' END + ' AS [backup_size]
							FROM msdb.dbo.backupset bs
							INNER JOIN msdb.dbo.backupmediafamily bmf ON bmf.[media_set_id] = bs.[media_set_id]
							WHERE bmf.[physical_device_name] = (''' + @backupLocation + @backupFileName + N''')
							ORDER BY bs.[backup_set_id] DESC'
		SET @queryToRun = [dbo].[ufn_formatSQLQueryForLinkedServer](@sqlServerName, @queryToRun)
		SET @queryToRun = N' SELECT   @backupStartDate = [backup_start_date]
									, @backupDurationSec = [backup_duration_sec]
									, @backupSizeBytes = [backup_size]
							FROM (' + @queryToRun + N')X'
		IF @debugMode=1	EXEC [dbo].[usp_logPrintMessage] @customMessage = @queryToRun, @raiseErrorAsPrint = 0, @messagRootLevel = @executionLevel, @messageTreelevel = 1, @stopExecution=0

		SET @queryParameters = N'@backupStartDate [datetime] OUTPUT, @backupDurationSec [int] OUTPUT, @backupSizeBytes [bigint] OUTPUT'

		EXEC sp_executesql @queryToRun, @queryParameters, @backupStartDate = @backupStartDate OUT
														, @backupDurationSec = @backupDurationSec OUT
														, @backupSizeBytes = @backupSizeBytes OUT
	end

--------------------------------------------------------------------------------------------------
--verify backup, if option is selected
IF @flgOptions & 16 = 16 AND @errorCode = 0 
	begin
		SET @queryToRun	= N'RESTORE VERIFYONLY FROM DISK=''' + @backupLocation + @backupFileName + N''''
		IF @optionBackupWithChecksum=1
			SET @queryToRun = @queryToRun + N' WITH CHECKSUM'

		IF @debugMode=1	EXEC [dbo].[usp_logPrintMessage] @customMessage = @queryToRun, @raiseErrorAsPrint = 0, @messagRootLevel = @executionLevel, @messageTreelevel = 1, @stopExecution=0
		EXEC @errorCode = [dbo].[usp_sqlExecuteAndLog]	@sqlServerName	= @sqlServerName,
														@dbName			= @dbName,
														@module			= 'dbo.usp_mpDatabaseBackup',
														@eventName		= 'database backup verify',
														@queryToRun  	= @queryToRun,
														@flgOptions		= @flgOptions,
														@executionLevel	= @nestedExecutionLevel,
														@debugMode		= @debugMode
	end

--------------------------------------------------------------------------------------------------
IF @errorCode = 0 
	begin
		--log backup database information
		SET @eventData='<backupset><detail>' + 
							'<database_name>' + @dbName + '</database_name>' + 
							'<type>' + @backupType + '</type>' + 
							'<start_date>' + CONVERT([varchar](24), ISNULL(@backupStartDate, GETDATE()), 121) + '</start_date>' + 
							'<duration>' + REPLICATE('0', 2-LEN(CAST(@backupDurationSec / 3600 AS [varchar]))) + CAST(@backupDurationSec / 3600 AS [varchar]) + 'h'
												+ ' ' + REPLICATE('0', 2-LEN(CAST((@backupDurationSec / 60) % 60 AS [varchar]))) + CAST((@backupDurationSec / 60) % 60 AS [varchar]) + 'm'
												+ ' ' + REPLICATE('0', 2-LEN(CAST(@backupDurationSec % 60 AS [varchar]))) + CAST(@backupDurationSec % 60 AS [varchar]) + 's' + '</duration>' + 
							'<size>' + CONVERT([varchar](32), CAST(@backupSizeBytes/(1024*1024*1.0) AS [money]), 1) + ' mb</size>' + 
							'<size_bytes>' + CAST(@backupSizeBytes AS [varchar](32)) + '</size_bytes>' + 
							'<verified>' + CASE WHEN @flgOptions & 16 = 16 AND @errorCode = 0  THEN 'Yes' ELSE 'No' END + '</verified>' + 
							'<file_name>' + @backupFileName + '</file_name>' + 
							'<error_code>' + CAST(@errorCode AS [varchar](32)) + '</error_code>' + 
						'</detail></backupset>'

		EXEC [dbo].[usp_logEventMessage]	@sqlServerName	= @sqlServerName,
											@dbName			= @dbName,
											@module			= 'dbo.usp_mpDatabaseBackup',
											@eventName		= 'database backup',
											@eventMessage	= @eventData,
											@eventType		= 0 /* info */
	end

--------------------------------------------------------------------------------------------------
--performing backup cleanup
IF @errorCode = 0 AND ISNULL(@retentionDays,0) <> 0
	begin
		SELECT	@backupType = SUBSTRING(@backupFileName, LEN(@backupFileName)-CHARINDEX('.', REVERSE(@backupFileName))+2, CHARINDEX('.', REVERSE(@backupFileName)))

		SET @nestedExecutionLevel = @executionLevel + 1

		EXEC [dbo].[usp_mpDatabaseBackupCleanup]	@sqlServerName			= @sqlServerName,
													@dbName					= @dbName,
													@backupLocation			= @backupLocation,
													@backupFileExtension	= @backupType,
													@flgOptions				= @flgOptions,
													@retentionDays			= @retentionDays,
													@executionLevel			= @nestedExecutionLevel,
													@debugMode				= @debugMode
	end

RETURN @errorCode
GO


/*---------------------------------------------------------------------------------------------------------------------*/
/* patch module: monitoring																							   */
/*---------------------------------------------------------------------------------------------------------------------*/
RAISERROR('Patching module: MONITORING', 10, 1) WITH NOWAIT

SET QUOTED_IDENTIFIER ON 
GO
SET ANSI_NULLS ON 
GO

RAISERROR('Create procedure: [dbo].[usp_monGetTransactionsStatus]', 10, 1) WITH NOWAIT
GO
IF  EXISTS (
	    SELECT * 
	      FROM sys.objects 
	     WHERE object_id = OBJECT_ID(N'[dbo].[usp_monGetTransactionsStatus]') 
	       AND type in (N'P', N'PC'))
DROP PROCEDURE [dbo].[usp_monGetTransactionsStatus]
GO

CREATE PROCEDURE [dbo].[usp_monGetTransactionsStatus]
		@projectCode			[varchar](32)=NULL,
		@sqlServerNameFilter	[sysname]='%',
		@debugMode				[bit]=0
/* WITH ENCRYPTION */
AS

-- ============================================================================
-- Copyright (c) 2004-2016 Dan Andrei STEFAN (danandrei.stefan@gmail.com)
-- ============================================================================
-- Author			 : Dan Andrei STEFAN
-- Create date		 : 12.01.2016
-- Module			 : Database Analysis & Performance Monitoring
-- ============================================================================

SET NOCOUNT ON

------------------------------------------------------------------------------------------------------------------------------------------
DECLARE @projectID				[smallint],
		@sqlServerName			[sysname],
		@instanceID				[smallint],
		@sqlServerVersion		[sysname],
		@SQLMajorVersion		[tinyint],
		@executionLevel			[tinyint],
		@queryToRun				[nvarchar](4000),
		@strMessage				[nvarchar](4000)


/*-------------------------------------------------------------------------------------------------------------------------------*/
IF object_id('tempdb..#blockedSessionInfo') IS NOT NULL  DROP TABLE #blockedSessionInfo

CREATE TABLE #blockedSessionInfo
(
	[id]					[int] IDENTITY(1,1),
	[session_id]			[smallint],
	[blocking_session_id]	[smallint],
	[wait_duration_sec]		[int],
	[wait_type]				[nvarchar](60)
)

/*-------------------------------------------------------------------------------------------------------------------------------*/
IF object_id('tempdb..#sessionTempdbUsage') IS NOT NULL  DROP TABLE #sessionTempdbUsage

CREATE TABLE #sessionTempdbUsage
(
	[id]					[int] IDENTITY(1,1),
	[session_id]			[smallint],
	[request_id]			[smallint],
	[space_used_mb]			[int]
)
 
/*-------------------------------------------------------------------------------------------------------------------------------*/
IF object_id('tempdb..#transactionInfo') IS NOT NULL  DROP TABLE #transactionInfo

CREATE TABLE #transactionInfo
(
	[id]						[int] IDENTITY(1,1),
	[transaction_begin_time]	[datetime],
	[elapsed_time_seconds]		[bigint],
	[session_id]				[smallint],
	[database_name]				[sysname]
)


/*-------------------------------------------------------------------------------------------------------------------------------*/
IF object_id('tempdb..#monTransactionsStatus') IS NOT NULL  DROP TABLE #monTransactionsStatus

CREATE TABLE #monTransactionsStatus
(
	[id]								[int] IDENTITY(1,1),
	[server_name]						[sysname],
	[database_name]						[sysname],
	[session_id]						[smallint],
	[transaction_begin_time]			[datetime],
	[host_name]							[sysname],
	[program_name]						[sysname],
	[login_name]						[sysname],
	[last_request_elapsed_time_seconds]	[bigint],
	[transaction_elapsed_time_seconds]	[bigint],
	[sessions_blocked]					[smallint],
	[sql_handle]						[varbinary](64),
	[request_completed]					[bit],
	[is_session_blocked]				[bit],
	[wait_duration_sec]					[int],
	[wait_type]							[nvarchar](60),
	[tempdb_space_used_mb]				[int]
)

SET @executionLevel = 0

------------------------------------------------------------------------------------------------------------------------------------------
--get value for critical alert threshold
DECLARE   @alertThresholdWarning [int] 

SELECT	@alertThresholdWarning = MIN([warning_limit])
FROM	[monitoring].[alertThresholds]
WHERE	[alert_name] IN ('Uncommitted Transaction Elapsed Time (sec)', 'Running Transaction Elapsed Time (sec)')
		AND [category] = 'performance'
		AND [is_warning_limit_enabled]=1
SET @alertThresholdWarning = ISNULL(@alertThresholdWarning, 900)

------------------------------------------------------------------------------------------------------------------------------------------
--get default project code
IF @projectCode IS NULL
	SELECT	@projectCode = [value]
	FROM	[dbo].[appConfigurations]
	WHERE	[name] = 'Default project code'
			AND [module] = 'common'

SELECT @projectID = [id]
FROM [dbo].[catalogProjects]
WHERE [code] = @projectCode 

IF @projectID IS NULL
	begin
		SET @strMessage=N'The value specifief for Project Code is not valid.'
		RAISERROR(@strMessage, 16, 1) WITH NOWAIT
	end


------------------------------------------------------------------------------------------------------------------------------------------
--
-------------------------------------------------------------------------------------------------------------------------
SET @strMessage='--Step 1: Delete existing information...'
EXEC [dbo].[usp_logPrintMessage] @customMessage = @strMessage, @raiseErrorAsPrint = 0, @messagRootLevel = @executionLevel, @messageTreelevel = 0, @stopExecution=0

DELETE sut
FROM [monitoring].[statsTransactionsStatus]	sut
INNER JOIN [dbo].[catalogInstanceNames] cin ON cin.[id] = sut.[instance_id] AND cin.[project_id] = sut.[project_id]
WHERE cin.[project_id] = @projectID
		AND cin.[name] LIKE @sqlServerNameFilter

DELETE lsam
FROM [dbo].[logAnalysisMessages]	lsam
INNER JOIN [dbo].[catalogInstanceNames] cin ON cin.[id] = lsam.[instance_id] AND cin.[project_id] = lsam.[project_id]
WHERE cin.[project_id] = @projectID
		AND cin.[name] LIKE @sqlServerNameFilter
		AND lsam.[descriptor]='dbo.usp_monGetTransactionsStatus'


-------------------------------------------------------------------------------------------------------------------------
SET @strMessage='--Step 2: Get Instance Details Information...'
EXEC [dbo].[usp_logPrintMessage] @customMessage = @strMessage, @raiseErrorAsPrint = 0, @messagRootLevel = @executionLevel, @messageTreelevel = 0, @stopExecution=0
		
DECLARE crsActiveInstances CURSOR LOCAL FAST_FORWARD FOR 	SELECT	cin.[instance_id], cin.[instance_name], cin.[version]
															FROM	[dbo].[vw_catalogInstanceNames] cin
															WHERE 	cin.[project_id] = @projectID
																	AND cin.[instance_active]=1
																	AND cin.[instance_name] LIKE @sqlServerNameFilter
															ORDER BY cin.[instance_name]
OPEN crsActiveInstances
FETCH NEXT FROM crsActiveInstances INTO @instanceID, @sqlServerName, @sqlServerVersion
WHILE @@FETCH_STATUS=0
	begin
		SET @strMessage='--	Analyzing server: ' + @sqlServerName
		EXEC [dbo].[usp_logPrintMessage] @customMessage = @strMessage, @raiseErrorAsPrint = 0, @messagRootLevel = @executionLevel, @messageTreelevel = 1, @stopExecution=0

		BEGIN TRY
			SELECT @SQLMajorVersion = REPLACE(LEFT(ISNULL(@sqlServerVersion, ''), 2), '.', '') 
		END TRY
		BEGIN CATCH
			SET @SQLMajorVersion = 8
		END CATCH

		TRUNCATE TABLE #blockedSessionInfo
		TRUNCATE TABLE #transactionInfo
		TRUNCATE TABLE #monTransactionsStatus

		IF @SQLMajorVersion > 8
			begin
				SET @queryToRun = N''
				SET @queryToRun = @queryToRun + N'SELECT  owt.[session_id]
														, owt.[blocking_session_id]
														, owt.[wait_duration_ms] / 1000
														, owt.[wait_type]
												FROM sys.dm_os_waiting_tasks owt WITH (READPAST)
												INNER JOIN sys.dm_exec_sessions es WITH (READPAST) ON es.[session_id] = owt.[session_id]'
				SET @queryToRun = [dbo].[ufn_formatSQLQueryForLinkedServer](@sqlServerName, @queryToRun)
				IF @debugMode=1	EXEC [dbo].[usp_logPrintMessage] @customMessage = @queryToRun, @raiseErrorAsPrint = 0, @messagRootLevel = @executionLevel, @messageTreelevel = 1, @stopExecution=0
				
				BEGIN TRY
						INSERT	INTO #blockedSessionInfo([session_id], [blocking_session_id], [wait_duration_sec], [wait_type])
								EXEC (@queryToRun)
				END TRY
				BEGIN CATCH
					SET @strMessage = ERROR_MESSAGE()
					PRINT @strMessage
					INSERT	INTO [dbo].[logAnalysisMessages]([instance_id], [project_id], [event_date_utc], [descriptor], [message])
							SELECT  @instanceID
									, @projectID
									, GETUTCDATE()
									, 'dbo.usp_monGetTransactionsStatus'
									, '[session-info]:' + @strMessage
				END CATCH


				SET @queryToRun = N''
				SET @queryToRun = @queryToRun + N'SELECT  tat.[transaction_begin_time]
														, ISNULL(tasdt.[elapsed_time_seconds], ABS(DATEDIFF(ss, tat.[transaction_begin_time], GETDATE()))) [elapsed_time_seconds]
														, ISNULL(tst.[session_id], tasdt.[session_id]) AS [session_id]
														, DB_NAME(tdt.[database_id]) AS [database_name]
												FROM sys.dm_tran_active_transactions						tat WITH (READPAST)
												LEFT JOIN sys.dm_tran_session_transactions					tst WITH (READPAST)		ON	tst.[transaction_id] = tat.[transaction_id]
												LEFT JOIN sys.dm_tran_database_transactions					tdt WITH (READPAST)		ON	tdt.[transaction_id] = tat.[transaction_id]
												LEFT JOIN sys.dm_tran_active_snapshot_database_transactions tasdt WITH (READPAST)	ON	tasdt.[transaction_id] = tat.[transaction_id] 
												WHERE ISNULL(tasdt.[elapsed_time_seconds], 0) >= ' + CAST(@alertThresholdWarning AS [nvarchar])
				SET @queryToRun = [dbo].[ufn_formatSQLQueryForLinkedServer](@sqlServerName, @queryToRun)
				IF @debugMode=1	EXEC [dbo].[usp_logPrintMessage] @customMessage = @queryToRun, @raiseErrorAsPrint = 0, @messagRootLevel = @executionLevel, @messageTreelevel = 1, @stopExecution=0
				
				BEGIN TRY
						INSERT	INTO #transactionInfo([transaction_begin_time], [elapsed_time_seconds], [session_id], [database_name])
								EXEC (@queryToRun)
				END TRY
				BEGIN CATCH
					SET @strMessage = ERROR_MESSAGE()
					PRINT @strMessage
					INSERT	INTO [dbo].[logAnalysisMessages]([instance_id], [project_id], [event_date_utc], [descriptor], [message])
							SELECT  @instanceID
									, @projectID
									, GETUTCDATE()
									, 'dbo.usp_monGetTransactionsStatus'
									, '[transaction-info]:' + @strMessage
				END CATCH


				SET @queryToRun = N''
				SET @queryToRun = @queryToRun + N'SELECT [session_id], [request_id], SUM([space_used_mb]) AS [space_used_mb]
												FROM (
														SELECT	[session_id], [request_id],
																SUM(([internal_objects_alloc_page_count] - [internal_objects_dealloc_page_count])*8)/1024 AS [space_used_mb]
														FROM sys.dm_db_task_space_usage
														GROUP BY [session_id], [request_id]
														)x
												WHERE x.[space_used_mb] > 0
												GROUP BY [session_id], [request_id]'
				SET @queryToRun = [dbo].[ufn_formatSQLQueryForLinkedServer](@sqlServerName, @queryToRun)
				IF @debugMode=1	EXEC [dbo].[usp_logPrintMessage] @customMessage = @queryToRun, @raiseErrorAsPrint = 0, @messagRootLevel = @executionLevel, @messageTreelevel = 1, @stopExecution=0
				
				BEGIN TRY
						INSERT	INTO #sessionTempdbUsage([session_id], [request_id], [space_used_mb])
								EXEC (@queryToRun)
				END TRY
				BEGIN CATCH
					SET @strMessage = ERROR_MESSAGE()
					PRINT @strMessage
					INSERT	INTO [dbo].[logAnalysisMessages]([instance_id], [project_id], [event_date_utc], [descriptor], [message])
							SELECT  @instanceID
									, @projectID
									, GETUTCDATE()
									, 'dbo.usp_monGetTransactionsStatus'
									, '[session-tempdb-info]:' + @strMessage
				END CATCH

			
				SET @queryToRun = N''
				SET @queryToRun = @queryToRun + N'SELECT  @@SERVERNAME AS [server_name]
														, es.[session_id]
														, er.[request_id]
														, es.[host_name]
														, es.[program_name]
														, CASE WHEN ISNULL(es.[login_name], '''') <> '''' THEN es.[login_name] ELSE sp.[loginame] END [login_name]
														, DATEDIFF(ss, es.[last_request_start_time], es.[last_request_end_time]) AS [last_request_elapsed_time_seconds]
														, sp.[sql_handle]
														, CASE WHEN er.[session_id] IS NULL THEN 1 ELSE 0 END AS [request_completed]
												FROM sys.dm_exec_sessions es WITH (READPAST)
												INNER JOIN master.dbo.sysprocesses sp WITH (READPAST) ON sp.[spid] = es.[session_id]
												LEFT JOIN sys.dm_exec_requests er WITH (READPAST) ON er.[session_id] = es.[session_id]'
				SET @queryToRun = [dbo].[ufn_formatSQLQueryForLinkedServer](@sqlServerName, @queryToRun)

				SET @queryToRun = N'SELECT x. [server_name]
										 , x.[session_id]
										 , ti.[database_name]
										 , x.[host_name]
										 , x.[program_name]
										 , x.[login_name]
										 , ti.[transaction_begin_time]
										 , CASE WHEN x.[last_request_elapsed_time_seconds] < 0 THEN 0 ELSE x.[last_request_elapsed_time_seconds] END AS [last_request_elapsed_time_seconds]
										 , ti.[elapsed_time_seconds] AS [transaction_elapsed_time_seconds]
										 , bk.[sessions_blocked]
										 , x.[sql_handle]
										 , x.[request_completed]
										 , CASE WHEN si.[blocking_session_id] IS NOT NULL THEN 1 ELSE 0 END AS [is_session_blocked]
										 , si.[wait_duration_sec]
										 , si.[wait_type]
										 , stu.[space_used_mb] AS [tempdb_space_used_mb]
									FROM (' + @queryToRun + N') x
									INNER JOIN #transactionInfo ti ON ti.[session_id] = x.[session_id]
									LEFT JOIN #sessionTempdbUsage stu ON stu.[session_id] = x.[session_id] AND stu.[request_id] = x.[request_id]
									LEFT JOIN 
										(
											SELECT si.[session_id], ISNULL(bk.[sessions_blocked], 0) AS [sessions_blocked]
											FROM #blockedSessionInfo si
											LEFT JOIN
													(
														SELECT [blocking_session_id], COUNT(*) AS [sessions_blocked]
														FROM #blockedSessionInfo 
														GROUP BY [blocking_session_id]
													)bk ON bk.[blocking_session_id] = si.[session_id]
											UNION
											SELECT [blocking_session_id] AS [session_id], COUNT(*) AS [sessions_blocked]
											FROM #blockedSessionInfo 
											WHERE [blocking_session_id] IS NOT NULL
											GROUP BY [blocking_session_id]
										)bk ON bk.[session_id] = x.[session_id]
									LEFT JOIN #blockedSessionInfo si ON si.[session_id] = x.[session_id]
									'

				IF @debugMode=1	EXEC [dbo].[usp_logPrintMessage] @customMessage = @queryToRun, @raiseErrorAsPrint = 0, @messagRootLevel = @executionLevel, @messageTreelevel = 1, @stopExecution=0

				BEGIN TRY
						INSERT	INTO #monTransactionsStatus([server_name], [session_id], [database_name], [host_name], [program_name], [login_name], [transaction_begin_time], [last_request_elapsed_time_seconds], [transaction_elapsed_time_seconds], [sessions_blocked], [sql_handle], [request_completed], [is_session_blocked], [wait_duration_sec], [wait_type], [tempdb_space_used_mb])
								EXEC (@queryToRun)
				END TRY
				BEGIN CATCH
					SET @strMessage = ERROR_MESSAGE()
					PRINT @strMessage
					INSERT	INTO [dbo].[logAnalysisMessages]([instance_id], [project_id], [event_date_utc], [descriptor], [message])
							SELECT  @instanceID
									, @projectID
									, GETUTCDATE()
									, 'dbo.usp_monGetTransactionsStatus'
									, '[uncommitted-info]:' + @strMessage
				END CATCH
			end								
				
		/* save results to stats table */
		INSERT INTO [monitoring].[statsTransactionsStatus]([instance_id], [project_id], [event_date_utc]
																, [database_name], [session_id], [transaction_begin_time], [host_name], [program_name], [login_name]
																, [last_request_elapsed_time_sec], [transaction_elapsed_time_sec], [sessions_blocked], [sql_handle]
																, [request_completed], [is_session_blocked], [wait_duration_sec], [wait_type], [tempdb_space_used_mb])
				SELECT    @instanceID, @projectID, GETUTCDATE()
						, [database_name], [session_id], [transaction_begin_time], [host_name], [program_name], [login_name]
						, [last_request_elapsed_time_seconds], [transaction_elapsed_time_seconds], [sessions_blocked], [sql_handle]
						, [request_completed], [is_session_blocked], [wait_duration_sec], [wait_type], [tempdb_space_used_mb]
				FROM #monTransactionsStatus
								
		FETCH NEXT FROM crsActiveInstances INTO @instanceID, @sqlServerName, @sqlServerVersion
	end
CLOSE crsActiveInstances
DEALLOCATE crsActiveInstances
GO


/*---------------------------------------------------------------------------------------------------------------------*/
USE [dbaTDPMon]
GO
SELECT * FROM [dbo].[appConfigurations] WHERE [module] = 'common' AND [name] = 'Application Version'
GO

RAISERROR('* Done *', 10, 1) WITH NOWAIT

