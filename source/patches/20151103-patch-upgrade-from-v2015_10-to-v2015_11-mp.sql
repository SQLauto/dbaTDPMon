USE [dbaTDPMon]
GO

UPDATE [dbo].[appConfigurations] SET [value] = N'2015.11.03' WHERE [module] = 'common' AND [name] = 'Application Version'
GO

RAISERROR('Create procedure: [dbo].[usp_logEventMessage]', 10, 1) WITH NOWAIT
GO---
IF  EXISTS (
	    SELECT * 
	      FROM sysobjects 
	     WHERE id = OBJECT_ID(N'[dbo].[usp_logEventMessage]') 
	       AND type in (N'P', N'PC'))
DROP PROCEDURE [dbo].[usp_logEventMessage]
GO

GO
CREATE PROCEDURE [dbo].[usp_logEventMessage]
		@projectCode			[sysname]=NULL,
		@sqlServerName			[sysname]=NULL,
		@dbName					[sysname] = NULL,
		@objectName				[nvarchar](512) = NULL,
		@childObjectName		[sysname] = NULL,
		@module					[sysname],
		@eventName				[nvarchar](256) = NULL,
		@parameters				[nvarchar](512) = NULL,			/* may contain the attach file name */
		@eventMessage			[varchar](8000) = NULL,
		@eventType				[smallint]=1,	/*	0 - info
													1 - alert 
													2 - job-history
													3 - report-html
													4 - action
													5 - backup-job-history
													6 - alert-custom
												*/
		@recipientsList			[nvarchar](1024) = NULL,
		@isEmailSent			[bit]=0,
		@isFloodControl			[bit]=0
/* WITH ENCRYPTION */
AS

-- ============================================================================
-- Copyright (c) 2004-2015 Dan Andrei STEFAN (danandrei.stefan@gmail.com)
-- ============================================================================
-- Author			 : Dan Andrei STEFAN
-- Create date		 : 05.11.2014
-- Module			 : Database Analysis & Performance Monitoring
-- ============================================================================

SET NOCOUNT ON

DECLARE @projectID					[smallint],
		@instanceID					[smallint]

-----------------------------------------------------------------------------------------------------
--get default project code
IF @projectCode IS NULL
	SELECT	@projectCode = [value]
	FROM	[dbo].[appConfigurations]
	WHERE	[name] = 'Default project code'
			AND [module] = 'common'

SELECT @projectID = [id]
FROM [dbo].[catalogProjects]
WHERE [code] = @projectCode 

-----------------------------------------------------------------------------------------------------
SELECT  @instanceID = [id] 
FROM	[dbo].[catalogInstanceNames]  
WHERE	[name] = @sqlServerName
		AND [project_id] = @projectID

-----------------------------------------------------------------------------------------------------
--xml corrections
SET @eventMessage = REPLACE(@eventMessage, CHAR(38), CHAR(38) + 'amp;')

-----------------------------------------------------------------------------------------------------
INSERT	INTO [dbo].[logEventMessages]([project_id], [instance_id], [event_date_utc], [module], [parameters], [event_name], [database_name], [object_name], [child_object_name], [message], [send_email_to], [event_type], [is_email_sent], [flood_control])
		SELECT @projectID, @instanceID, GETUTCDATE(), @module, @parameters, @eventName, @dbName, @objectName, @childObjectName, @eventMessage, @recipientsList, @eventType, @isEmailSent, @isFloodControl

RETURN 0
GO


RAISERROR('Create procedure: [dbo].[usp_logEventMessageAndSendEmail]', 10, 1) WITH NOWAIT
GO---
IF  EXISTS (
	    SELECT * 
	      FROM sys.objects 
	     WHERE object_id = OBJECT_ID(N'[dbo].[usp_logEventMessageAndSendEmail]') 
	       AND type in (N'P', N'PC'))
DROP PROCEDURE [dbo].[usp_logEventMessageAndSendEmail]
GO

SET QUOTED_IDENTIFIER ON
GO
CREATE PROCEDURE [dbo].[usp_logEventMessageAndSendEmail]
		@projectCode			[sysname]=NULL,
		@sqlServerName			[sysname]=NULL,
		@dbName					[sysname] = NULL,
		@objectName				[nvarchar](512) = NULL,
		@childObjectName		[sysname] = NULL,
		@module					[sysname],
		@eventName				[nvarchar](256) = NULL,
		@parameters				[nvarchar](512) = NULL,			/* may contain the attach file name */
		@eventMessage			[varchar](8000) = NULL,
		@dbMailProfileName		[sysname] = NULL,
		@recipientsList			[nvarchar](1024) = NULL,
		@eventType				[smallint]=1,	/*	0 - info
													1 - alert 
													2 - job-history
													3 - report-html
													4 - action
													5 - backup-job-history
													6 - alert-custom
												*/
		@additionalOption		[smallint]=0
/* WITH ENCRYPTION */
WITH RECOMPILE
AS

-- ============================================================================
-- Copyright (c) 2004-2015 Dan Andrei STEFAN (danandrei.stefan@gmail.com)
-- ============================================================================
-- Author			 : Dan Andrei STEFAN
-- Create date		 : 05.11.2014
-- Module			 : Database Analysis & Performance Monitoring
-- ============================================================================

SET NOCOUNT ON

DECLARE @projectID					[smallint],
		@instanceID					[smallint],		
		@alertFrequency				[int],
		@alertSent					[int],
		@isEmailSent				[bit],
		@isFloodControl				[bit],
		@HTMLBody					[nvarchar](max),
		@emailSubject				[nvarchar](256),
		@queryToRun					[nvarchar](max),
		@ReturnValue				[int],
		@ErrMessage					[nvarchar](256),
		@clientName					[nvarchar](260),
		@eventData					[varchar](8000),
		@ignoreAlertsForError1222	[bit],
		@errorCode					[int],
		@eventMessageXML			[xml]
		

DECLARE   @handle				[int]
		, @PrepareXmlStatus		[int]

SET @ReturnValue=1

-----------------------------------------------------------------------------------------------------
--get default project code
IF @projectCode IS NULL
	SELECT	@projectCode = [value]
	FROM	[dbo].[appConfigurations]
	WHERE	[name] = 'Default project code'
			AND [module] = 'common'

SELECT @projectID = [id]
FROM [dbo].[catalogProjects]
WHERE [code] = @projectCode 

-----------------------------------------------------------------------------------------------------
SELECT  @instanceID = [id] 
FROM	[dbo].[catalogInstanceNames]  
WHERE	[name] = @sqlServerName
		AND [project_id] = @projectID

		
-----------------------------------------------------------------------------------------------------
--
-----------------------------------------------------------------------------------------------------
--get default database mail profile name from configuration table
IF UPPER(@dbMailProfileName)='NULL'
	SET @dbMailProfileName = NULL
		
IF @dbMailProfileName IS NULL
	SELECT	@dbMailProfileName=[value] 
	FROM	[dbo].[appConfigurations] 
	WHERE	[name]='Database Mail profile name to use for sending emails'
			AND [module] = 'common'

IF @recipientsList = ''		SET @recipientsList = NULL
IF @dbMailProfileName = ''	SET @dbMailProfileName = NULL


IF @recipientsList IS NULL
	SELECT	@recipientsList=[value] 
	FROM	[dbo].[appConfigurations] 
	WHERE  (@eventType IN (1, 6) AND [name]='Default recipients list - Alerts (semicolon separated)' AND [module] = 'common')
		OR (@eventType IN (2, 5) AND [name]='Default recipients list - Job Status (semicolon separated)' AND [module] = 'common')
		OR (@eventType=3 AND [name]='Default recipients list - Reports (semicolon separated)' AND [module] = 'common')

-----------------------------------------------------------------------------------------------------
--get alert repeat frequency, default every 60 minutes
-----------------------------------------------------------------------------------------------------
SELECT	@alertFrequency = [value]
FROM	[dbo].[appConfigurations]
WHERE	[name]='Alert repeat interval (minutes)'
		AND [module] = 'common'

SELECT @alertFrequency = ISNULL(@alertFrequency, 60)


-----------------------------------------------------------------------------------------------------
--check what alerts can be ignored
-----------------------------------------------------------------------------------------------------
SELECT	@ignoreAlertsForError1222 = CASE WHEN LOWER([value])='true' THEN 1 ELSE 0 END
FROM	[dbo].[appConfigurations]
WHERE	[name]='Ignore alerts for: Error 1222 - Lock request time out period exceeded'
		AND [module] = 'common'

SET @ignoreAlertsForError1222 = ISNULL(@ignoreAlertsForError1222, 0)


-----------------------------------------------------------------------------------------------------
--check if alert should be sent
-----------------------------------------------------------------------------------------------------
SET @alertSent=0
IF @projectID IS NOT NULL AND @instanceID IS NOT NULL
	SELECT @alertSent=COUNT(*)
	FROM [dbo].[logEventMessages]
	WHERE	[instance_id] = @instanceID
			AND [project_id] = @projectID
			AND [module] = @module
			AND [event_name] = @eventName
			AND [event_type] = @eventType
			AND ISNULL([database_name], '') = ISNULL(@dbName, '')
			AND ISNULL([object_name], '') = ISNULL(@objectName, '')
			AND ISNULL([child_object_name], '') = ISNULL(@childObjectName, '')
			AND ISNULL([parameters], '') = ISNULL(@parameters, '')
			AND DATEDIFF(mi, [event_date_utc], GETUTCDATE()) BETWEEN 0 AND @alertFrequency
			AND [is_email_sent] = 1
			AND @eventType IN (1, 6)


-----------------------------------------------------------------------------------------------------
--processing the xml message
-----------------------------------------------------------------------------------------------------
SET @eventMessage = REPLACE(@eventMessage, '&', '&amp;')

SET @eventMessageXML = CAST(@eventMessage AS [xml])
SET @HTMLBody = N''

-----------------------------------------------------------------------------------------------------
--alert details
IF @eventType=1	AND @eventMessageXML IS NOT NULL
	begin
		EXEC @PrepareXmlStatus= sp_xml_preparedocument @handle OUTPUT, @eventMessageXML  

		SET @HTMLBody =@HTMLBody + COALESCE(
								CAST ( ( 
										SELECT	li = 'error number: ' + CAST([error_code] AS [nvarchar](32)), '',
												li = [error_string], '',
												li = [query_executed], '',
												li = 'duration: ' + CAST([duration_seconds] AS [nvarchar](32)) + ' seconds', ''
										FROM (
												SELECT  *
												FROM    OPENXML(@handle, '/alert/detail', 2)  
														WITH (
																[error_code]		[int],
																[error_string]		[nvarchar](max),
																[query_executed]	[nvarchar](max),
																[duration_seconds]	[bigint]
															)  
											)x
										FOR XML PATH('ul'), TYPE 
							) AS NVARCHAR(MAX) )
							, '') ;
			
		SELECT	@errorCode = [error_code]
		FROM (
				SELECT  *
				FROM    OPENXML(@handle, '/alert/detail', 2)  
						WITH (
								[error_code]		[int],
								[error_string]		[nvarchar](max),
								[query_executed]	[nvarchar](max),
								[duration_seconds]	[bigint]
							)  
			)x
		EXEC sp_xml_removedocument @handle 
	end

-----------------------------------------------------------------------------------------------------
--alert details
IF @eventType=6	AND @eventMessageXML IS NOT NULL
	begin
		EXEC @PrepareXmlStatus= sp_xml_preparedocument @handle OUTPUT, @eventMessageXML  

		SET @HTMLBody =@HTMLBody + COALESCE(
								CAST ( ( 
										SELECT	
												li = 'machine-name: ' + [machine_name], '',
												li = 'measure-unit: ' + [measure_unit], '',
												li = 'current-value: ' + CAST([current_value] AS [varchar](32)), '',
												li = 'current-percentage: ' + CAST([current_percentage] AS [varchar](32)), '',
												li = 'reference-value: ' + CAST([refference_value] AS [varchar](32)), '',
												li = 'reference-percentage: ' + CAST([refference_percentage] AS [varchar](32)), '',
												li = 'threshold-value: ' + CAST([threshold_value] AS [varchar](32)), '',
												li = 'threshold-percentage: ' + CAST([threshold_percentage] AS [varchar](32)), '',
												li = 'severity: ' + [severity], '',
												li = 'event-date (utc): ' + CAST([event_date_utc] AS [varchar](32)), ''
										FROM (
												SELECT  *
												FROM    OPENXML(@handle, '/alert/detail', 2)  
														WITH (											
																[severity]					[sysname],
																[instance_name]				[sysname],
																[machine_name]				[sysname],
																[counter_name]				[sysname],
																[target_name]				[sysname],
																[measure_unit]				[sysname],
																[current_value]				[numeric](18,3),
																[current_percentage]		[numeric](18,3),
																[refference_value]			[numeric](18,3),
																[refference_percentage]		[numeric](18,3),
																[threshold_value]			[numeric](18,3),
																[threshold_percentage]		[numeric](18,3),
																[event_date_utc]			[sysname]															)  
											)x
										FOR XML PATH('ul'), TYPE 
							) AS NVARCHAR(MAX) )
							, '') ;
		
		EXEC sp_xml_removedocument @handle 
	end

-----------------------------------------------------------------------------------------------------
--job-status details
IF @eventType IN (2, 5)	AND @eventMessageXML IS NOT NULL
	begin
		EXEC @PrepareXmlStatus= sp_xml_preparedocument @handle OUTPUT, @eventMessageXML  

		SET @HTMLBody =@HTMLBody + COALESCE(
							N'<TABLE BORDER="1">' +
							N'<TR>' +
								N'<TH>Step ID</TH>
									<TH>Step Name</TH>
									<TH>Run Status</TH>
									<TH>Run Date</TH>
									<TH>Run Time</TH>
									<TH>Run Duration</TH>
									<TH>Message</TH>' +
								CAST ( ( 
										SELECT	TD = [step_id], '',
												TD = [step_name], '',
												TD = [run_status], '',
												TD = [run_date], '',
												TD = [run_time], '',
												TD = [duration], '',
												TD = [message], ''
										FROM (
												SELECT  *
												FROM    OPENXML(@handle, '/job-history/job-step', 2)  
														WITH (
																[step_id]		[int],
																[step_name]		[sysname],
																[run_status]	[nvarchar](32),
																[run_date]		[nvarchar](32),
																[run_time]		[nvarchar](32),
																[duration]		[nvarchar](32),
																[message]		[nvarchar](max)
															)  
											)x
										FOR XML PATH('TR'), TYPE 
							) AS NVARCHAR(MAX) ) +
							N'</TABLE>', '') ;

		EXEC sp_xml_removedocument @handle 

		-- go out in style
		SET @HTMLBody = N'
						<style>
							body {
								/*background-color: #F0F8FF;*/
								font-family: Arial, Tahoma;
							}
							h1 {
								font-size: 20px;
								font-weight: bold;
							}
							table {
								border-color: #ccc;
								border-collapse: collapse;
							}
							th {
								font-size: 12px;
								font-weight: bold;
								font-color: #000000;
								border-spacing: 2px;
								border-style: solid;
								border-width: 1px;
								border-color: #ccc;
								background-color: #00AEEF;
								padding: 4px;
							}
							td {
								font-size: 12px;
								border-spacing: 2px;
								border-style: solid;
								border-width: 1px;
								border-color: #ccc;
								background-color: #EDF8FE;
								padding: 4px;
								white-space: nowrap;
							}
						</style>' + @HTMLBody
	end

-----------------------------------------------------------------------------------------------------
--report details
IF @eventType=3	AND @eventMessageXML IS NOT NULL
	begin
		EXEC @PrepareXmlStatus= sp_xml_preparedocument @handle OUTPUT, @eventMessageXML  

		DECLARE @xmlMessage			[nvarchar](max),
				@xmlFileName		[nvarchar](max),
				@xmlHTTPAddress		[nvarchar](max),
				@xmlRelativePath	[nvarchar](max)

		SELECT TOP 1 @xmlMessage = [message],
						@xmlFileName = [file_name],
						@xmlHTTPAddress = [http_address],
						@xmlRelativePath = [relative_path]
		FROM    OPENXML(@handle, '/report-html/detail', 2)  
				WITH (
						[message]		[nvarchar](max),
						[file_name]		[nvarchar](max),
						[http_address]	[nvarchar](max),
						[relative_path]	[nvarchar](max)
					)  

		EXEC sp_xml_removedocument @handle 

		SET @HTMLBody =@HTMLBody + @xmlMessage + N'<br>File name: <b>' + @xmlFileName + N'</b><br>'
	
		IF @xmlHTTPAddress IS NOT NULL				
			begin
				SET @HTMLBody = @HTMLBody + N'Full report file is available for download <A HREF="' + @xmlHTTPAddress + @xmlRelativePath + @xmlFileName + '">here</A><br>'
				SET @HTMLBody = @HTMLBody + N'Browser support: IE 8, Firefox 3.5 and Google Chrome 7 (on lower versions, some features may be missing).<br>'
			end
	end


-----------------------------------------------------------------------------------------------------
--backup-job-status details
IF @eventType IN (5) AND @eventMessageXML IS NOT NULL
	begin
		DECLARE   @jobStartTime [datetime]

		EXEC @PrepareXmlStatus= sp_xml_preparedocument @handle OUTPUT, @eventMessageXML  
			
		SELECT    @jobStartTime = MIN([job_step_start_time])
		FROM	(
					SELECT CASE WHEN [run_date] IS NOT NULL AND [run_time] IS NOT NULL
								THEN CONVERT([datetime], ([run_date] + ' ' + [run_time]), 120) 
								ELSE GETDATE()
							END AS [job_step_start_time]
					FROM (
							SELECT  *
							FROM    OPENXML(@handle, '/job-history/job-step', 2)  
									WITH (
											[step_id]		[int],
											[step_name]		[sysname],
											[run_status]	[nvarchar](32),
											[run_date]		[nvarchar](32),
											[run_time]		[nvarchar](32),
											[duration]		[nvarchar](32)
										)  
						)x
				)y

		EXEC sp_xml_removedocument @handle 

		DECLARE @xmlBackupSet TABLE
			(
				  [database_name]	[sysname]
				, [type]			[nvarchar](32)
				, [start_date]		[nvarchar](32)
				, [duration]		[nvarchar](32)
				, [size]			[nvarchar](32)
				, [size_bytes]		[bigint]
				, [verified]		[nvarchar](8)
				, [file_name]		[nvarchar](512)
				, [error_code]		[int]
			)


		DECLARE @xmlSkippedActions TABLE
			(
				  [database_name]	[sysname]
				, [backup_type]		[nvarchar](32)
				, [date]			[nvarchar](32)
				, [reason]			[nvarchar](512)
			)

		INSERT	INTO @xmlBackupSet([database_name], [type], [start_date], [duration], [size], [size_bytes], [verified], [file_name], [error_code])
				SELECT [database_name], [type], [start_date], [duration], [size], [size_bytes], [verified], [file_name], [error_code]
				FROM (
						SELECT	  ref.value ('database_name[1]', 'sysname') as [database_name]
								, ref.value ('type[1]', 'nvarchar(32)') as [type]
								, ref.value ('start_date[1]', '[datetime]') as [start_date]
								, ref.value ('duration[1]', 'nvarchar(32)') as [duration]
								, ref.value ('size[1]', 'nvarchar(32)') as [size]
								, ref.value ('size_bytes[1]', 'bigint') as [size_bytes]
								, ref.value ('verified[1]', 'nvarchar(8)') as [verified]
								, ref.value ('file_name[1]', 'nvarchar(512)') as [file_name]
								, ref.value ('error_code[1]', 'int') as [error_code]
						FROM (
								SELECT	CAST([message] AS [xml]) AS [message_xml]
								FROM	[dbo].[logEventMessages]
								WHERE	[message] LIKE '<backupset>%'
										AND ISNULL([project_id], 0) = ISNULL(@projectID, 0)
										AND ISNULL([instance_id], 0) = ISNULL(@instanceID, 0)
										AND [event_type]=0
							)x CROSS APPLY [message_xml].nodes ('//backupset/detail') R(ref)								
					)bs
				WHERE [start_date] BETWEEN @jobStartTime AND GETDATE()


		INSERT	INTO @xmlSkippedActions ([database_name], [backup_type], [date], [reason])
				SELECT [database_name], [backup_type], [date], [reason]
				FROM (
						SELECT	  ref.value ('affected_object[1]', 'sysname') as [database_name]
								, ref.value ('type[1]', 'nvarchar(32)') as [backup_type]
								, ref.value ('date[1]', '[datetime]') as [date]
								, ref.value ('reason[1]', 'nvarchar(512)') as [reason]
						FROM (
								SELECT	CAST([message] AS [xml]) AS [message_xml]
								FROM	[dbo].[logEventMessages]
								WHERE	[message] LIKE '<skipaction>%'
										AND ISNULL([project_id], 0) = ISNULL(@projectID, 0)
										AND ISNULL([instance_id], 0) = ISNULL(@instanceID, 0)
										AND [event_type]=0
										AND [event_name] = 'database backup'
							)x CROSS APPLY [message_xml].nodes ('//skipaction/detail') R(ref)	
					) sa
				WHERE [date] BETWEEN @jobStartTime AND GETDATE()


		SET @HTMLBody =@HTMLBody + N'<br><br>'
		SET @HTMLBody =@HTMLBody + COALESCE(
							N'<TABLE BORDER="1">' +
							N'<TR>' +
								N'	<TH>Database Name</TH>
									<TH>Backup Type</TH>
									<TH>Start Time</TH>
									<TH>Run Duration</TH>
									<TH>Size</TH>
									<TH>Verified</TH>
									<TH>File Name</TH>
									<TH>Error Code</TH>' +
								CAST ( ( 
										SELECT	TD = [database_name], '',
												TD = [type], '',
												TD = [start_date], '',
												TD = [duration], '',
												TD = [size], '',
												TD = [verified], '',
												TD = [file_name], '',
												TD = [error_code], ''
										FROM (
												SELECT	TOP (100) PERCENT *
												FROM @xmlBackupSet							
												ORDER BY [database_name]
											)x
										FOR XML PATH('TR'), TYPE 
							) AS NVARCHAR(MAX) ) +
							N'</TABLE>', '') ;

		IF (SELECT COUNT(*) FROM @xmlSkippedActions)>0
			begin
				SET @HTMLBody =@HTMLBody + N'<br><br>'
				SET @HTMLBody =@HTMLBody + COALESCE(
									N'<TABLE BORDER="1">' +
									N'<TR>' +
										N'	<TH>Database Name</TH>
											<TH>Backup Type</TH>
											<TH>Date</TH>
											<TH>Reason</TH>' +
										CAST ( ( 
												SELECT	TD = [database_name], '',
														TD = [backup_type], '',
														TD = [date], '',
														TD = [reason], ''
												FROM (
														SELECT	TOP (100) PERCENT *
														FROM @xmlSkippedActions							
														ORDER BY [database_name]
													)x
												FOR XML PATH('TR'), TYPE 
									) AS NVARCHAR(MAX) ) +
									N'</TABLE>', '') ;
			end

		--if any of the backups had failed, send notification
		IF @additionalOption=0
			SELECT @additionalOption = COUNT(*)
			FROM @xmlBackupSet
			WHERE [error_code]<>0
	end


SET @HTMLBody = REPLACE(@HTMLBody, N'&amp;', N'&')
SET @HTMLBody = REPLACE(@HTMLBody, N'&amp;lt;', N'<')
SET @HTMLBody = REPLACE(@HTMLBody, N'&amp;gt;', N'>')


-----------------------------------------------------------------------------------------------------
--get notification status
-----------------------------------------------------------------------------------------------------
IF @eventType IN (2, 5)
	begin
		DECLARE @notifyOnlyFailedJobs [nvarchar](32)

		SELECT	@notifyOnlyFailedJobs = LOWER([value])
		FROM	[dbo].[appConfigurations]
		WHERE	[name]='Notify job status only for Failed jobs'
				AND [module] = 'common'


		IF @notifyOnlyFailedJobs = 'true' AND @additionalOption=0
			SET @recipientsList=NULL
	end
	
IF @eventType IN (1)
	begin
		IF @ignoreAlertsForError1222=1 AND @errorCode=1222
			begin
				SET @alertSent=1
				SET @isFloodControl=1
				SET @recipientsList=NULL
			end
	end

-----------------------------------------------------------------------------------------------------
--
-----------------------------------------------------------------------------------------------------
SET @isEmailSent	= 0 
SET @isFloodControl	= 0

IF @alertSent=0
	begin
		SET @projectCode = ISNULL(@projectCode, 'N/A')
		
		SET @emailSubject = CASE WHEN @projectID IS NOT NULL THEN N'[' + @projectCode + '] ' ELSE N'' END 
							+ CASE	WHEN @eventType=0 THEN N'info'
									WHEN @eventType=1 THEN N'alert'
									WHEN @eventType IN (2, 5) THEN N'job status'
									WHEN @eventType=3 THEN N'report'
									WHEN @eventType=4 THEN N'action'
									WHEN @eventType=6 THEN N'alert'
								END	 
							+ N' on ' + N'[' +  @sqlServerName + ']: ' 
							+ CASE WHEN @dbName IS NOT NULL THEN QUOTENAME(@dbName) + N' - ' ELSE N'' END 
							+ CASE	WHEN @eventType=1 THEN N'[error] - '
									WHEN @eventType IN (2, 5) THEN 
											CASE	WHEN @additionalOption=0 
													THEN N'[completed] - '
													ELSE N'[failed] - '
											END	
									ELSE N''
								END
							+ @eventName
							+ CASE WHEN @objectName IS NOT NULL THEN N' - ' + @objectName ELSE N'' END
			
		SET @HTMLBody = @HTMLBody + N'<HR><P STYLE="font-family: Arial, Tahoma; font-size:10px;">This email is sent by [' + @@SERVERNAME + N'].	Generated by dbaTDPMon.<br><P>'
				
		-----------------------------------------------------------------------------------------------------		
		IF @recipientsList IS NOT NULL AND @dbMailProfileName IS NOT NULL
			begin
				-----------------------------------------------------------------------------------------------------
				--sending email using dbmail
				-----------------------------------------------------------------------------------------------------
				IF @eventType in (2, 3, 5) AND @parameters IS NOT NULL
					EXEC msdb.dbo.sp_send_dbmail  @profile_name		= @dbMailProfileName
												, @recipients		= @recipientsList
												, @subject			= @emailSubject
												, @body				= @HTMLBody
												, @file_attachments = @parameters
												, @body_format		= 'HTML'
				ELSE
					EXEC msdb.dbo.sp_send_dbmail  @profile_name		= @dbMailProfileName
												, @recipients		= @recipientsList
												, @subject			= @emailSubject
												, @body				= @HTMLBody
												, @file_attachments = NULL
												, @body_format		= 'HTML'			
					
				SET @isEmailSent=1

				EXEC [dbo].[usp_logPrintMessage] @customMessage='email sent', @raiseErrorAsPrint=1, @messagRootLevel=0, @messageTreelevel=1, @stopExecution=0
			end
	end
ELSE
	begin
		SET @isFloodControl=1
	end

SET @eventData = SUBSTRING(CAST(@eventMessageXML AS [varchar](8000)), 1, 8000)
EXEC [dbo].[usp_logEventMessage]	@projectCode			= @projectCode,
									@sqlServerName			= @sqlServerName,
									@dbName					= @dbName,
									@objectName				= @objectName,
									@childObjectName		= @childObjectName,
									@module					= @module,
									@eventName				= @eventName,
									@parameters				= @parameters,
									@eventMessage			= @eventData,
									@eventType				= @eventType,
									@recipientsList			= @recipientsList,
									@isEmailSent			= @isEmailSent,
									@isFloodControl			= @isFloodControl


RETURN @ReturnValue
GO

RAISERROR('Create procedure: [dbo].[usp_sqlAgentJobCheckStatus]', 10, 1) WITH NOWAIT
GO
SET QUOTED_IDENTIFIER ON 
GO
SET ANSI_NULLS ON 
GO

if exists (select * from dbo.sysobjects where id = object_id(N'[dbo].[usp_sqlAgentJobCheckStatus]') and OBJECTPROPERTY(id, N'IsProcedure') = 1)
drop procedure [dbo].[usp_sqlAgentJobCheckStatus]
GO

CREATE PROCEDURE dbo.usp_sqlAgentJobCheckStatus
		@sqlServerName			[sysname],
		@jobName				[varchar](255),
		@strMessage				[varchar](8000)=''	OUTPUT,	
		@currentRunning			[int]=0 			OUTPUT,			
		@lastExecutionStatus	[int]=0 			OUTPUT,			
		@lastExecutionDate		[varchar](10)=''	OUTPUT,		
		@lastExecutionTime 		[varchar](8)=''		OUTPUT,	
		@runningTimeSec			[bigint]=0			OUTPUT,
		@selectResult			[bit]=0,
		@extentedStepDetails	[bit]=0,		
		@debugMode				[bit]=0
/* WITH ENCRYPTION */
AS

-- ============================================================================
-- Copyright (c) 2004-2015 Dan Andrei STEFAN (danandrei.stefan@gmail.com)
-- ============================================================================
-- Author			 : Dan Andrei STEFAN
-- Create date		 : 2004-2014
-- Module			 : Database Analysis & Performance Monitoring
-- ============================================================================

------------------------------------------------------------------------------------------------------------------------------------------
DECLARE 	@Message 			[varchar](8000), 
			@StepName			[varchar](255),
			@JobID				[varchar](255),
			@StepID				[int],
			@JobSessionID		[int],
			@RunDate			[varchar](10),
			@RunDateDetail		[varchar](10),
			@RunTime			[varchar](8),
			@RunTimeDetail		[varchar](8),
			@RunDuration		[varchar](8),
			@RunDurationDetail	[varchar](8),
			@RunStatus			[varchar](32),
			@RunStatusDetail	[varchar](32),
			@RunDurationLast	[varchar](8),
			@EventTime			[datetime],		
			@ReturnValue		[int],
			@queryToRun			[nvarchar](4000)

SET NOCOUNT ON

IF OBJECT_ID('tempdb..#tmpCheck') IS NOT NULL DROP TABLE #tmpCheck
CREATE TABLE #tmpCheck (Result varchar(1024))

IF ISNULL(@sqlServerName, '')=''
	begin
		SET @queryToRun=N'--	ERROR: The specified value for SOURCE server is not valid.'
		RAISERROR(@queryToRun, 16, 1) WITH NOWAIT
		RETURN 1
	end

IF LEN(@jobName)=0 OR ISNULL(@jobName, '')=''
	begin
		RAISERROR('--ERROR: Must specify a job name.', 10, 1) WITH NOWAIT
		RETURN 1
	end

SET @queryToRun=N'SELECT [srvid] FROM master.dbo.sysservers WHERE [srvname]=''' + @sqlServerName + ''''
TRUNCATE TABLE #tmpCheck
INSERT INTO #tmpCheck EXEC (@queryToRun)
IF (SELECT count(*) FROM #tmpCheck)=0
	begin
		SET @queryToRun=N'--	ERROR: SOURCE server [' + @sqlServerName + '] is not defined as linked server on THIS server [' + @sqlServerName + '].'
		RAISERROR(@queryToRun, 16, 1) WITH NOWAIT
		RETURN 1
	end

---------------------------------------------------------------------------------------------
SET	@strMessage			= NULL
SET	@currentRunning		= NULL
SET	@lastExecutionStatus= NULL
SET	@lastExecutionDate	= NULL
SET	@lastExecutionTime 	= NULL
SET	@runningTimeSec		= NULL


---------------------------------------------------------------------------------------------
SET @ReturnValue	= 5 --Unknown

SET @queryToRun=N'SELECT  CAST([job_id] AS [varchar](255)) AS [job_id] FROM [msdb].[dbo].[sysjobs] WHERE [name]=''' + @jobName + ''''
SET @queryToRun = [dbo].[ufn_formatSQLQueryForLinkedServer](@sqlServerName, @queryToRun)
IF @debugMode = 1 PRINT @queryToRun

TRUNCATE TABLE #tmpCheck
INSERT INTO #tmpCheck EXEC (@queryToRun)
------------------------------------------------------------------------------------------------------------------------------------------
IF (SELECT COUNT(*) FROM #tmpCheck)=0
	begin
		SET @strMessage='--SQL Server Agent: The specified job name [' + @jobName + '] does not exists on this server [' + @sqlServerName + ']'
		IF @debugMode=1
			RAISERROR(@strMessage, 10, 1) WITH NOWAIT
		SET @currentRunning = 0
		SET @ReturnValue = -5 --Unknown
	end
ELSE
	begin
		SELECT TOP 1 @JobID = [Result] FROM #tmpCheck
			
		IF OBJECT_ID('tempdb..#runningSQLAgentJobsProcess') IS NOT NULL DROP TABLE #runningSQLAgentJobsProcess
		CREATE TABLE #runningSQLAgentJobsProcess
			(
				  [step_id]		[int], 
				  [job_id]		[uniqueidentifier],
				  [session_id]	[int]
			)
		
		--check for active processes started by SQL Agent job
		SET @currentRunning=0
		SET @queryToRun=N'SELECT DISTINCT sp.[step_id], sp.[job_id], sp.[spid]
						FROM (
							  SELECT  [step_id]
									, SUBSTRING([job_id], 7, 2) + SUBSTRING([job_id], 5, 2) + SUBSTRING([job_id], 3, 2) + LEFT([job_id], 2) + ''-'' + SUBSTRING([job_id], 11, 2) + SUBSTRING([job_id], 9, 2) + ''-'' + SUBSTRING([job_id], 15, 2) + SUBSTRING([job_id], 13, 2) + ''-'' + SUBSTRING([job_id], 17, 4) + ''-'' + RIGHT([job_id], 12) AS [job_id] 
									, [spid]
 							  FROM (
									SELECT SUBSTRING([program_name], CHARINDEX('': Step'', [program_name]) + 7, LEN([program_name]) - CHARINDEX('': Step'', [program_name]) - 7) [step_id]
										 , SUBSTRING([program_name], CHARINDEX(''(Job 0x'', [program_name]) + 7, CHARINDEX('' : Step '', [program_name]) - CHARINDEX(''(Job 0x'', [program_name]) - 7) [job_id]
										 , [spid]
			 						FROM [master].[dbo].[sysprocesses] 
									WHERE [program_name] LIKE ''SQLAgent - %JobStep%''
								   ) sp
							) sp
						INNER JOIN [msdb].[dbo].[sysjobs] sj ON sj.[job_id] = sp.[job_id]
						WHERE sj.[name]= ''' + @jobName + N'''
						UNION
						SELECT DISTINCT sjs.[step_id], sj.[job_id], sp.[spid]
						FROM [master].[dbo].[sysprocesses] sp
						INNER JOIN [msdb].[dbo].[sysjobs]		sj  ON sj.[name] = sp.[program_name]
						INNER JOIN [msdb].[dbo].[sysjobsteps]	sjs ON sjs.[job_id] = sj.[job_id]
						INNER JOIN [msdb].[dbo].[sysjobhistory] sjh ON sjh.[job_id] = sj.[job_id] AND sjh.[step_id] = sjs.[step_id] AND sjh.[run_status] = 4
						WHERE sj.[name]= ''' + @jobName + N''''
		SET @queryToRun = [dbo].[ufn_formatSQLQueryForLinkedServer](@sqlServerName, @queryToRun)
		IF @debugMode = 1 PRINT @queryToRun
		INSERT	INTO #runningSQLAgentJobsProcess([step_id], [job_id], [session_id])
				EXEC (@queryToRun)

		SET @StepID = NULL
		SET @JobSessionID = NULL

		SELECT @currentRunning = COUNT(*) FROM #runningSQLAgentJobsProcess
		SELECT TOP 1  @StepID = [step_id]
					, @JobID  = CAST([job_id] AS [varchar](255))
					, @JobSessionID = [session_id]
		FROM #runningSQLAgentJobsProcess	

		IF OBJECT_ID('tempdb..#runningSQLAgentJobsProcess') IS NOT NULL DROP TABLE #runningSQLAgentJobsProcess
	
		IF @currentRunning > 0 
			begin
				SET @queryToRun=N'SELECT [step_name] FROM [msdb].[dbo].[sysjobsteps] WHERE [step_id]=' + CAST(@StepID AS [nvarchar]) + ' AND [job_id]=''' + @JobID + ''''
				SET @queryToRun = [dbo].[ufn_formatSQLQueryForLinkedServer](@sqlServerName, @queryToRun)
				IF @debugMode = 1 PRINT @queryToRun

				TRUNCATE TABLE #tmpCheck
				INSERT INTO #tmpCheck EXEC (@queryToRun)
				SELECT TOP 1 @StepName=Result FROM #tmpCheck

				SET @lastExecutionStatus=4 -- in progress
				IF @debugMode=1
					RAISERROR(@strMessage, 10, 1) WITH NOWAIT
				SET @ReturnValue=4

				--get job start date/time
				IF OBJECT_ID('tempdb..#jobStartInfo') IS NOT NULL DROP TABLE #jobStartInfo
				CREATE TABLE #jobStartInfo
					(
						[start_date]	[varchar](16), 
						[start_time]	[varchar](16), 
						[run_status]	[int], 
						[event_time]	[datetime]
					)

				SET @queryToRun=N'SELECT TOP 1 CAST(h.[run_date] AS varchar) AS [start_date]
											, CAST(h.[run_time] AS varchar) AS [start_time]
											, NULL AS [run_status]
											, GETDATE() AS [event_time]
								FROM [msdb].[dbo].[sysjobhistory] h
								WHERE h.[job_id]=''' + @JobID + N''' 
										AND h.[instance_id] > (
																/* last job completion id */
																SELECT TOP 1 h1.[instance_id]
																FROM [msdb].[dbo].[sysjobhistory] h1
																WHERE h1.[job_id]=''' + @JobID + N''' 
																		AND [step_name] =''(Job outcome)''
																ORDER BY h1.[instance_id] DESC
																)
								ORDER BY h.[instance_id] ASC'
				SET @queryToRun = [dbo].[ufn_formatSQLQueryForLinkedServer](@sqlServerName, @queryToRun)
				IF @debugMode = 1 PRINT @queryToRun

				INSERT	INTO #jobStartInfo([start_date], [start_time], [run_status], [event_time])
						EXEC (@queryToRun)

				
				IF (SELECT COUNT(*) FROM #jobStartInfo)=0
					begin
						IF @StepID <> 1
							begin
								/* job was cancelled, but process is still running, probably performing a rollback */
								SET @queryToRun=N'SELECT TOP 1 CAST(h.[run_date] AS varchar) AS [start_date]
															, CAST(h.[run_time] AS varchar) AS [start_time]
															, h.[run_status]
															, GETDATE() AS [event_time]
												FROM [msdb].[dbo].[sysjobhistory] h
												WHERE h.[job_id]=''' + @JobID + N''' 
														AND h.[instance_id] = (
																				/* last job completion id */
																				SELECT TOP 1 h1.[instance_id]
																				FROM [msdb].[dbo].[sysjobhistory] h1
																				WHERE h1.[job_id]=''' + @JobID + N''' 
																						AND [step_name] =''(Job outcome)''
																				ORDER BY h1.[instance_id] DESC
																				)
												ORDER BY h.[instance_id] ASC'
							end
						ELSE
							begin
								SET @queryToRun=N'SELECT  REPLACE(SUBSTRING(CONVERT([varchar](19), [login_time], 120), 1, 10), ''-'', '''')  AS [start_date]
														, REPLACE(SUBSTRING(CONVERT([varchar](19), [login_time], 120), 12, 19), '':'', '''') AS [start_time]
														, 4 AS [run_status]
														, GETDATE() AS [event_time]
												FROM [master].[dbo].[sysprocesses]
												WHERE [spid] = ' + CAST(@JobSessionID AS [nvarchar])
							end
						SET @queryToRun = [dbo].[ufn_formatSQLQueryForLinkedServer](@sqlServerName, @queryToRun)
						IF @debugMode = 1 PRINT @queryToRun

						INSERT	INTO #jobStartInfo([start_date], [start_time], [run_status], [event_time])
								EXEC (@queryToRun)
					end
									
				SET @RunDate	= NULL
				SET @RunTime	= NULL
				SET @EventTime	= NULL
				SELECT TOP 1  @RunDate	 = [start_date]
							, @RunTime	 = [start_time]
							, @RunStatus = CAST(ISNULL([run_status], @lastExecutionStatus) AS [varchar]) 
							, @EventTime = [event_time]
				FROM #jobStartInfo
	

				SET @RunTime = REPLICATE('0', 6 - LEN(@RunTime)) + @RunTime
				SET @RunTime = SUBSTRING(@RunTime, 1, 2) + ':' + SUBSTRING(@RunTime, 3, 2) + ':' + SUBSTRING(@RunTime, 5, 2)
				SET @RunDate = SUBSTRING(@RunDate, 1, 4) + '-' + SUBSTRING(@RunDate, 5, 2) + '-' + SUBSTRING(@RunDate, 7, 2)

				SET @lastExecutionDate = @RunDate
				SET @lastExecutionTime = @RunTime
				SET @runningTimeSec = [dbo].[ufn_getMilisecondsBetweenDates](CONVERT([datetime], @lastExecutionDate + ' ' + @lastExecutionTime, 120), @EventTime) / 1000

				SET @RunStatus = CASE @RunStatus WHEN '0' THEN 'Failed'
												 WHEN '1' THEN 'Succeded'				
												 WHEN '2' THEN 'Retry'
												 WHEN '3' THEN 'Canceled'
												 WHEN '4' THEN 'In progress'
								 END
				
				SET @strMessage=                         '--Job currently running step: [' + CAST(@StepID AS varchar) + '] - [' + @StepName + ']'
				SET @strMessage=@strMessage + CHAR(13) + '--Job started at            : [' + ISNULL(@RunDate, '') + ' ' + ISNULL(@RunTime, '') + ']'
				SET @strMessage=@strMessage + CHAR(13) + '--Execution status          : [' + ISNULL(@RunStatus, '') + ']'	
			end
		ELSE
			begin
				IF OBJECT_ID('tempdb..#jobLastRunDetails') IS NOT NULL DROP TABLE #jobLastRunDetails
				CREATE TABLE #jobLastRunDetails
					(
						[message]		[varchar](4000), 
						[step_id]		[int], 
						[step_name]		[varchar](255), 
						[run_status]	[int], 
						[run_date]		[varchar](16), 
						[run_time]		[varchar](16), 
						[run_duration]	[varchar](16), 
						[event_time]	[datetime])

				SET @queryToRun=N'SELECT TOP 1 h.[message], h.[step_id], h.[step_name], h.[run_status]
											, CAST(h.[run_date] AS varchar) AS [run_date], CAST(h.[run_time] AS varchar) AS [run_time], CAST(h.[run_duration] AS varchar) AS [run_duration]
											, GETDATE() AS [event_time]
								FROM [msdb].[dbo].[sysjobhistory] h
								WHERE	h.[job_id]=''' + @JobID + N''' 
										AND h.[step_name] <> ''(Job outcome)''
								ORDER BY h.[instance_id] DESC'
				SET @queryToRun = [dbo].[ufn_formatSQLQueryForLinkedServer](@sqlServerName, @queryToRun)
				IF @debugMode = 1 PRINT @queryToRun

				INSERT	INTO #jobLastRunDetails ([message], [step_id], [step_name], [run_status], [run_date], [run_time], [run_duration], [event_time])
						EXEC (@queryToRun)
				
				SET @Message	=null
				SET @StepID		=null
				SET @StepName	=null
				SET @lastExecutionStatus=null
				SET @RunStatus	=null
				SET @RunDate	=null
				SET @RunTime	=null
				SET @RunDuration=null
				SET @EventTime	=null
				SELECT TOP 1  @Message		= [message]
							, @StepID		= [step_id]
							, @StepName		= [step_name]
							, @RunDate		= [run_date]
							, @RunTime		= [run_time]
							, @RunDuration	= [run_duration] 
							, @EventTime	= [event_time]
				FROM #jobLastRunDetails
				
				SET @queryToRun=N'SELECT TOP 1 NULL AS [message], NULL AS [step_id], NULL AS [step_name], [run_status], NULL AS [run_date], NULL AS [run_time], CAST([run_duration] AS varchar) AS [RunDuration], NULL AS [event_time]
								FROM [msdb].[dbo].[sysjobhistory]
								WHERE	[job_id] = ''' + @JobID + N'''
										AND [step_name] =''(Job outcome)''
								ORDER BY [instance_id] DESC'
				SET @queryToRun = [dbo].[ufn_formatSQLQueryForLinkedServer](@sqlServerName, @queryToRun)
				IF @debugMode = 1 PRINT @queryToRun

				TRUNCATE TABLE #jobLastRunDetails
				INSERT	INTO #jobLastRunDetails ([message], [step_id], [step_name], [run_status], [run_date], [run_time], [run_duration], [event_time])
						EXEC (@queryToRun)
				
				SET @RunDurationLast=null
				SET @RunStatus=null
				SELECT TOP 1  @RunDurationLast	   = [run_duration]
							, @RunStatus		   = CAST([run_status] AS varchar)
							, @lastExecutionStatus = [run_status] 
				FROM #jobLastRunDetails
			
				--for failed jobs, get last step message
				IF @RunStatus=0
					begin
						SET @queryToRun='SELECT TOP 1 h.[message], NULL AS [step_id], NULL AS [step_name], NULL AS [run_status], NULL AS [run_date], NULL AS [run_time], NULL AS [run_duration], NULL AS [event_time]
									FROM [msdb].[dbo].[sysjobhistory] h
									WHERE h.[job_id]=''' + @JobID + ''' 
											AND h.[step_name] <> ''(Job outcome)'' 
											AND h.[run_status]=0
									ORDER BY h.[instance_id] DESC'
						SET @queryToRun = [dbo].[ufn_formatSQLQueryForLinkedServer](@sqlServerName, @queryToRun)
						IF @debugMode = 1 PRINT @queryToRun

						TRUNCATE TABLE #jobLastRunDetails
						INSERT	INTO #jobLastRunDetails ([message], [step_id], [step_name], [run_status], [run_date], [run_time], [run_duration], [event_time])
								EXEC (@queryToRun)

						SELECT TOP 1 @Message=[message] 
						FROM #jobLastRunDetails
						
						SET @lastExecutionStatus=0
					end

				SET @RunDurationLast=REPLICATE('0', 6 - LEN(@RunDurationLast)) + @RunDurationLast
				SET @runningTimeSec = CAST(SUBSTRING(@RunDurationLast, 1, LEN(@RunDurationLast) - 4) AS [bigint])*3600 + CAST(SUBSTRING(RIGHT(@RunDurationLast, 4), 1, 2) AS [bigint])*60 + CAST(SUBSTRING(RIGHT(@RunDurationLast, 4), 3, 2) AS [bigint])
				SET @RunDurationLast=SUBSTRING(@RunDurationLast, 1, LEN(@RunDurationLast) - 4) + ':' + SUBSTRING(RIGHT(@RunDurationLast, 4), 1, 2) + ':' + SUBSTRING(RIGHT(@RunDurationLast, 4), 3, 2)
				
				IF @lastExecutionStatus IS NULL
					begin
						SET @RunStatus='Unknown'
						SET @lastExecutionStatus='5' 
					end

				SET @RunStatus = CASE @RunStatus WHEN '0' THEN 'Failed'
												 WHEN '1' THEN 'Succeded'				
												 WHEN '2' THEN 'Retry'
												 WHEN '3' THEN 'Canceled'
												 WHEN '4' THEN 'In progress'
								 END

				SET @RunTime=REPLICATE('0', 6 - LEN(@RunTime)) + @RunTime
				SET @RunTime=SUBSTRING(@RunTime, 1, 2) + ':' + SUBSTRING(@RunTime, 3, 2) + ':' + SUBSTRING(@RunTime, 5, 2)
				SET @RunDate=SUBSTRING(@RunDate, 1, 4) + '-' + SUBSTRING(@RunDate, 5, 2) + '-' + SUBSTRING(@RunDate, 7, 2)
				SET @RunDuration=REPLICATE('0', 6 - LEN(@RunDuration)) + @RunDuration
				--SET @RunDuration=SUBSTRING(@RunDuration, 1,2) + ':' + SUBSTRING(@RunDuration, 3,2) + ':' + SUBSTRING(@RunDuration, 5,2)
				SET @RunDuration=SUBSTRING(@RunDuration, 1, LEN(@RunDuration) - 4) + ':' + SUBSTRING(RIGHT(@RunDuration, 4), 1, 2) + ':' + SUBSTRING(RIGHT(@RunDuration, 4), 3, 2)
				
				SET @strMessage='--The specified job [' + @sqlServerName + '].[' + @jobName + '] is not currently running.'
				IF @RunStatus<>'Unknown'
					begin
						SET @strMessage=@strMessage + CHAR(13) + '--Last execution step			: [' + ISNULL(CAST(@StepID AS varchar), '') + '] - [' + ISNULL(@StepName, '') + ']'
						SET @strMessage=@strMessage + CHAR(13) + '--Last step finished at      	: [' + ISNULL(@RunDate, '') + ' ' + ISNULL(@RunTime, '') + ']'
						SET @strMessage=@strMessage + CHAR(13) + '--Last step running time		: [' + ISNULL(@RunDuration, '') + ']'
						SET @strMessage=@strMessage + CHAR(13) + '--Job execution time (total)	: [' + ISNULL(@RunDurationLast, '') + ']'	
					end
				SET @strMessage=@strMessage + CHAR(13) + '--Last job execution status  	: [' + ISNULL(@RunStatus, 'Unknown') + ']'	

				SET @lastExecutionDate=@RunDate
				SET @lastExecutionTime=@RunTime

				SET @ReturnValue=@lastExecutionStatus
			end

			IF @extentedStepDetails=1
				begin
					IF OBJECT_ID('tempdb..#jobRunStepDetails') IS NOT NULL DROP TABLE #jobRunStepDetails
					CREATE TABLE #jobRunStepDetails
						(
							[message]		[varchar](4000), 
							[step_id]		[int], 
							[step_name]		[varchar](255), 
							[run_status]	[int], 
							[run_date]		[varchar](16), 
							[run_time]		[varchar](16), 
							[run_duration]	[varchar](16), 
							[event_time]	[datetime])

					--get job execution details: steps execution status
					IF @currentRunning = 0 
						SET @queryToRun=N'SELECT   h.[message], h.[step_id], h.[step_name], h.[run_status]
												, CAST(h.[run_date] AS varchar) AS [run_date], CAST(h.[run_time] AS varchar) AS [run_time], CAST(h.[run_duration] AS varchar) AS [run_duration]
												, GETDATE() AS [event_time]
										FROM [msdb].[dbo].[sysjobhistory] h
										WHERE	 h.[instance_id] < (
																	SELECT TOP 1 [instance_id] 
																	FROM (	
																			SELECT TOP 2 h.[instance_id], h.[message], h.[step_id], h.[step_name], h.[run_status], CAST(h.[run_date] AS varchar) AS [run_date], CAST(h.[run_time] AS varchar) AS [run_time], CAST(h.[run_duration] AS varchar) AS [run_duration]
																			FROM [msdb].[dbo].[sysjobhistory] h
																			WHERE	h.[job_id]=''' + @JobID + N''' 
																					AND h.[step_name] =''(Job outcome)''
																			ORDER BY h.[instance_id] DESC
																		)A
																	) 
												AND	h.[instance_id] > ISNULL(
																	( SELECT [instance_id] 
																	FROM (	
																			SELECT TOP 2 h.[instance_id], h.[message], h.[step_id], h.[step_name], h.[run_status], CAST(h.[run_date] AS varchar) AS [run_date], CAST(h.[run_time] AS varchar) AS [run_time], CAST(h.[run_duration] AS varchar) AS [run_duration]
																			FROM [msdb].[dbo].[sysjobhistory] h
																			WHERE	h.[job_id]=''' + @JobID + N''' 
																					AND h.[step_name] =''(Job outcome)''
																			ORDER BY h.[instance_id] DESC
																		)A
																	WHERE [instance_id] NOT IN 
																		(
																		SELECT TOP 1 [instance_id] 
																		FROM (	SELECT TOP 2 h.[instance_id], h.[message], h.[step_id], h.[step_name], h.[run_status], CAST(h.[run_date] AS varchar) AS [run_date], CAST(h.[run_time] AS varchar) AS [run_time], CAST(h.[run_duration] AS varchar) AS [run_duration]
																				FROM [msdb].[dbo].[sysjobhistory] h
																				WHERE	h.[job_id]=''' + @JobID + N''' 
																						AND h.[step_name] =''(Job outcome)''
																				ORDER BY h.[instance_id] DESC
																			)A
																		)),0)
												AND h.[job_id] = ''' + @JobID + N'''
											ORDER BY h.[instance_id]'
					ELSE
						SET @queryToRun=N'SELECT   h.[message], h.[step_id], h.[step_name], h.[run_status]
												, CAST(h.[run_date] AS varchar) AS [run_date], CAST(h.[run_time] AS varchar) AS [run_time], CAST(h.[run_duration] AS varchar) AS [run_duration]
												, GETDATE() AS [event_time]
										FROM [msdb].[dbo].[sysjobhistory] h
										WHERE	 h.[instance_id] > (
																	SELECT TOP 1 [instance_id] 
																	FROM (	
																			SELECT TOP 2 h.[instance_id], h.[message], h.[step_id], h.[step_name], h.[run_status], CAST(h.[run_date] AS varchar) AS [run_date], CAST(h.[run_time] AS varchar) AS [run_time], CAST(h.[run_duration] AS varchar) AS [run_duration]
																			FROM [msdb].[dbo].[sysjobhistory] h
																			WHERE	h.[job_id]=''' + @JobID + N''' 
																					AND h.[step_name] =''(Job outcome)''
																			ORDER BY h.[instance_id] DESC
																		)A
																	) 
												AND j.[job_id] = ''' + @JobID + N'''
											ORDER BY h.[instance_id]'

					SET @queryToRun = [dbo].[ufn_formatSQLQueryForLinkedServer](@sqlServerName, @queryToRun)
					IF @debugMode = 1 PRINT @queryToRun

					TRUNCATE TABLE #jobRunStepDetails
					INSERT	INTO #jobRunStepDetails ([message], [step_id], [step_name], [run_status], [run_date], [run_time], [run_duration], [event_time])
							EXEC (@queryToRun)
						
					DECLARE @maxLengthStepName [int]
					SELECT @maxLengthStepName = MAX(LEN([step_name]))
					FROM #jobRunStepDetails
					
					SET @maxLengthStepName = ISNULL(@maxLengthStepName, 16)

					DECLARE crsJobDetails CURSOR FOR	SELECT DISTINCT   [step_id]
																		, [step_name]
																		, [run_status]
																		, [run_date]
																		, [run_time]
																		, [run_duration]
																		, [message]
														FROM #jobRunStepDetails
														ORDER BY [run_date], [run_time]
					OPEN crsJobDetails
					FETCH NEXT FROM crsJobDetails INTO @StepID, @StepName, @RunStatusDetail, @RunDateDetail, @RunTimeDetail, @RunDurationDetail, @queryToRun

					IF @@FETCH_STATUS=0
						begin
							SET @queryToRun='[' + LEFT('Run Date' + SPACE(10), 10) + '] [' + LEFT('RunTime' + SPACE(8), 8) +'] [' + LEFT('Status' + SPACE(12), 12) + '] [' + LEFT('Duration' + SPACE(20), 20) + '] [' + LEFT('ID' + SPACE(3), 3) + '] [' + LEFT('Step Name' + SPACE(@maxLengthStepName), @maxLengthStepName) + ']'
							SET @strMessage=@strMessage + CHAR(13) + @queryToRun
						end
						
					WHILE @@FETCH_STATUS=0
						begin								
							SET @RunStatusDetail = CASE @RunStatusDetail WHEN '0' THEN 'Failed'
																			WHEN '1' THEN 'Succeded'				
																			WHEN '2' THEN 'Retry'
																			WHEN '3' THEN 'Canceled'
																			WHEN '4' THEN 'In progress'
														END
	
							SET @RunTimeDetail=REPLICATE('0', 6 - LEN(@RunTimeDetail)) + @RunTimeDetail
							SET @RunTimeDetail=SUBSTRING(@RunTimeDetail, 1, 2) + ':' + SUBSTRING(@RunTimeDetail, 3, 2) + ':' + SUBSTRING(@RunTimeDetail, 5, 2)
							SET @RunDateDetail=SUBSTRING(@RunDateDetail, 1, 4) + '-' + SUBSTRING(@RunDateDetail, 5, 2) + '-' + SUBSTRING(@RunDateDetail, 7, 2)

							SET @RunDurationDetail=REPLICATE('0', 6 - LEN(@RunDurationDetail)) + @RunDurationDetail
								
							SET @strMessage=@strMessage + CHAR(13) + ISNULL(
									'[' + LEFT(@RunDateDetail + SPACE(10), 10) + '] ' + 
									'[' + LEFT(@RunTimeDetail + SPACE(8), 8) + '] ' + 
									'[' + LEFT(@RunStatusDetail + SPACE(12), 12) + '] ' + 
									'[' + LEFT(dbo.ufn_reportHTMLFormatTimeValue((CAST(SUBSTRING(@RunDurationDetail, 1, LEN(@RunDurationDetail) - 4) AS [bigint])*3600 + CAST(SUBSTRING(RIGHT(@RunDurationDetail, 4), 1, 2) AS [bigint])*60 + CAST(SUBSTRING(RIGHT(@RunDurationDetail, 4), 3, 2) AS [bigint]))*1000) + SPACE(20), 20) + '] ' + 
									'[' + LEFT(CAST(@StepID AS varchar) + SPACE(3), 3) + '] ' + 
									'[' + LEFT(@StepName + SPACE(@maxLengthStepName), @maxLengthStepName) + ']', '')

							FETCH NEXT FROM crsJobDetails INTO @StepID, @StepName, @RunStatusDetail, @RunDateDetail, @RunTimeDetail, @RunDurationDetail, @queryToRun
						end
					CLOSE crsJobDetails
					DEALLOCATE crsJobDetails					
				end

			--final error message
			IF @currentRunning = 0  AND @RunStatus='Failed'
				begin
					SET @strMessage=@strMessage + CHAR(13) + '--Job execution return this message: ' + ISNULL(@Message, '')
					IF @debugMode=1
						print '--Job execution return this message: ' + ISNULL(@Message, '')
				end
	end

SET @lastExecutionStatus = ISNULL(@lastExecutionStatus, 5) --Unknown
IF @debugMode=1
	print @strMessage
SET @ReturnValue=ISNULL(@ReturnValue, 0)
IF @selectResult=1
	SELECT @strMessage AS StrMessage, @currentRunning AS CurrentRunning, @lastExecutionStatus AS LastExecutionStatus, @lastExecutionDate AS LastExecutionDate, @lastExecutionTime AS LastExecutionTime, @runningTimeSec AS RunningTimeSec
RETURN @ReturnValue



GO
SET QUOTED_IDENTIFIER OFF 
GO
SET ANSI_NULLS ON 
GO

RAISERROR('Create procedure: [dbo].[usp_sqlAgentJobEmailStatusReport]', 10, 1) WITH NOWAIT
GO---
IF  EXISTS (
	    SELECT * 
	      FROM sysobjects 
	     WHERE id = OBJECT_ID(N'[dbo].[usp_sqlAgentJobEmailStatusReport]') 
	       AND type in (N'P', N'PC'))
DROP PROCEDURE [dbo].[usp_sqlAgentJobEmailStatusReport]
GO

CREATE PROCEDURE [dbo].[usp_sqlAgentJobEmailStatusReport]
		@sqlServerName			[sysname] = @@SERVERNAME,
		@jobName				[sysname],
		@logFileLocation		[nvarchar](512),
		@module					[varchar](32),
		@sendLogAsAttachment	[bit]=1,
		@eventType				[smallint]=2,
		@currentlyRunning		[bit] = 1,
		@debugMode				[bit] = 0
/* WITH ENCRYPTION */
AS

SET NOCOUNT ON

-- ============================================================================
-- Copyright (c) 2004-2015 Dan Andrei STEFAN (danandrei.stefan@gmail.com)
-- ============================================================================
-- Author			 : Dan Andrei STEFAN
-- Create date		 : 17.03.2015
-- Module			 : Database Analysis & Performance Monitoring
-- ============================================================================

DECLARE @eventMessageData			[varchar](8000),
		@jobID						[uniqueidentifier],
		@strMessage					[nvarchar](512),
		@lastCompletionInstanceID	[int],
		@queryToRun					[nvarchar](max),
		@queryParams				[nvarchar](1024)

-----------------------------------------------------------------------------------------------------
--get job id
SET @queryToRun = N''
SET @queryToRun = @queryToRun + N'SELECT [job_id] FROM [msdb].[dbo].[sysjobs] WHERE [name]=''' + @jobName + ''''
SET @queryToRun = [dbo].[ufn_formatSQLQueryForLinkedServer](@sqlServerName, @queryToRun)

SET @queryToRun = N'SELECT @jobID = [job_id] FROM (' + @queryToRun + N')inq'
SET @queryParams = '@jobID [uniqueidentifier] OUTPUT'

IF @debugMode=1	PRINT @queryToRun
EXEC sp_executesql @queryToRun, @queryParams, @jobID = @jobID OUTPUT

-----------------------------------------------------------------------------------------------------
--get last instance_id when job completed
SET @queryToRun = N''
SET @queryToRun = @queryToRun + N'SELECT MAX(h.[instance_id]) AS [instance_id]
					FROM [msdb].[dbo].[sysjobs] j 
					RIGHT JOIN [msdb].[dbo].[sysjobhistory] h ON j.[job_id] = h.[job_id] 
					WHERE	j.[job_id] = ''' + CAST(@jobID AS [nvarchar](36)) + N'''
							AND h.[step_name] =''(Job outcome)'''
SET @queryToRun = [dbo].[ufn_formatSQLQueryForLinkedServer](@sqlServerName, @queryToRun)

SET @queryToRun = N'SELECT @lastCompletionInstanceID = [instance_id] FROM (' + @queryToRun + N')inq'
SET @queryParams = '@lastCompletionInstanceID [int] OUTPUT'

IF @debugMode=1	PRINT @queryToRun
EXEC sp_executesql @queryToRun, @queryParams, @lastCompletionInstanceID = @lastCompletionInstanceID OUTPUT

SET @lastCompletionInstanceID = ISNULL(@lastCompletionInstanceID, 0)
-----------------------------------------------------------------------------------------------------

IF OBJECT_ID('tempdb..#jobHistory') IS NOT NULL
	DROP TABLE #jobHistory

CREATE TABLE #jobHistory
	(
		  [step_id]			[int]
		, [step_name]		[sysname]
		, [run_status]		[nvarchar](32)
		, [run_date]		[nvarchar](32)
		, [run_time]		[nvarchar](32)
		, [duration]		[nvarchar](32)
		, [message]			[nvarchar](max)
	)

SET @queryToRun = N''
IF @currentlyRunning = 0
	SET @queryToRun = @queryToRun + N'
			SELECT	[step_id]
					, [step_name]
					, [run_status]
					, SUBSTRING([run_date], 1, 4) + ''-'' + SUBSTRING([run_date], 5 ,2) + ''-'' + SUBSTRING([run_date], 7 ,2) AS [run_date]
					, SUBSTRING([run_time], 1, 2) + '':'' + SUBSTRING([run_time], 3, 2) + '':'' + SUBSTRING([run_time], 5, 2) AS [run_time]
					, SUBSTRING([run_duration], 1, 2) + ''h '' + SUBSTRING([run_duration], 3, 2) + ''m '' + SUBSTRING([run_duration], 5, 2) + ''s'' AS [duration]
					, [message]
			FROM (		
					SELECT    h.[step_id]
							, h.[step_name]
							, CASE h.[run_status]	WHEN ''0'' THEN ''Failed''
													WHEN ''1'' THEN ''Succeded''	
													WHEN ''2'' THEN ''Retry''
													WHEN ''3'' THEN ''Canceled''
													WHEN ''4'' THEN ''In progress''
													ELSE ''Unknown''
								END [run_status]
							, CAST(h.[run_date] AS varchar) AS [run_date]
							, REPLICATE(''0'', 6 - LEN(CAST(h.[run_time] AS varchar))) + CAST(h.[run_time] AS varchar) AS [run_time]
							, REPLICATE(''0'', 6 - LEN(CAST(h.[run_duration] AS varchar))) + CAST(h.[run_duration] AS varchar) AS [run_duration]
							, CASE WHEN [run_status] IN (0, 2) THEN LEFT(h.[message], 256) ELSE '''' END AS [message]
					FROM [msdb].[dbo].[sysjobhistory] h
					WHERE	 h.[instance_id] < (
												SELECT TOP 1 [instance_id] 
												FROM (	
														SELECT TOP 2 h.[instance_id], h.[message], h.[step_id], h.[step_name], h.[run_status], CAST(h.[run_date] AS varchar) AS [run_date], CAST(h.[run_time] AS varchar) AS [run_time], CAST(h.[run_duration] AS varchar) AS [run_duration]
														FROM [msdb].[dbo].[sysjobhistory] h
														WHERE	h.[job_id]= ''' + CAST(@jobID AS [nvarchar](36)) + N'''
																AND h.[step_name] =''(Job outcome)''
														ORDER BY h.[instance_id] DESC
													)A
												) 
							AND	h.[instance_id] > ISNULL(
												( SELECT [instance_id] 
												FROM (	
														SELECT TOP 2 h.[instance_id], h.[message], h.[step_id], h.[step_name], h.[run_status], CAST(h.[run_date] AS varchar) AS [run_date], CAST(h.[run_time] AS varchar) AS [run_time], CAST(h.[run_duration] AS varchar) AS [run_duration]
														FROM [msdb].[dbo].[sysjobhistory] h
														WHERE	h.[job_id]= ''' + CAST(@jobID AS [nvarchar](36)) + N'''
																AND h.[step_name] =''(Job outcome)''
														ORDER BY h.[instance_id] DESC
													)A
												WHERE [instance_id] NOT IN 
													(
													SELECT TOP 1 [instance_id] 
													FROM (	SELECT TOP 2 h.[instance_id], h.[message], h.[step_id], h.[step_name], h.[run_status], CAST(h.[run_date] AS varchar) AS [run_date], CAST(h.[run_time] AS varchar) AS [run_time], CAST(h.[run_duration] AS varchar) AS [run_duration]
															FROM [msdb].[dbo].[sysjobhistory] h
															WHERE	h.[job_id]= ''' + CAST(@jobID AS [nvarchar](36)) + N'''
																	AND h.[step_name] =''(Job outcome)''
															ORDER BY h.[instance_id] DESC
														)A
													)),0)
							AND h.[job_id] = ''' + CAST(@jobID AS [nvarchar](36)) + N'''
				)A'
ELSE
	SET @queryToRun = @queryToRun + N'
			SELECT	[step_id]
					, [step_name]
					, [run_status]
					, SUBSTRING([run_date], 1, 4) + ''-'' + SUBSTRING([run_date], 5 ,2) + ''-'' + SUBSTRING([run_date], 7 ,2) AS [run_date]
					, SUBSTRING([run_time], 1, 2) + '':'' + SUBSTRING([run_time], 3, 2) + '':'' + SUBSTRING([run_time], 5, 2) AS [run_time]
					, SUBSTRING([run_duration], 1, 2) + ''h '' + SUBSTRING([run_duration], 3, 2) + ''m '' + SUBSTRING([run_duration], 5, 2) + ''s'' AS [duration]
					, [message]
			FROM (		
					SELECT    h.[step_id]
							, h.[step_name]
							, CASE h.[run_status]	WHEN ''0'' THEN ''Failed''
													WHEN ''1'' THEN ''Succeded''	
													WHEN ''2'' THEN ''Retry''
													WHEN ''3'' THEN ''Canceled''
													WHEN ''4'' THEN ''In progress''
													ELSE ''Unknown''
								END [run_status]
							, CAST(h.[run_date] AS varchar) AS [run_date]
							, REPLICATE(''0'', 6 - LEN(CAST(h.[run_time] AS varchar))) + CAST(h.[run_time] AS varchar) AS [run_time]
							, REPLICATE(''0'', 6 - LEN(CAST(h.[run_duration] AS varchar))) + CAST(h.[run_duration] AS varchar) AS [run_duration]
							, CASE WHEN [run_status] IN (0, 2) THEN LEFT(h.[message], 256) ELSE '''' END AS [message]
					FROM [msdb].[dbo].[sysjobhistory] h
					WHERE	 h.[instance_id] > ISNULL((
														SELECT TOP 1 [instance_id] 
														FROM (	
																SELECT TOP 2 h.[instance_id], h.[message], h.[step_id], h.[step_name], h.[run_status], CAST(h.[run_date] AS varchar) AS [run_date], CAST(h.[run_time] AS varchar) AS [run_time], CAST(h.[run_duration] AS varchar) AS [run_duration]
																FROM [msdb].[dbo].[sysjobhistory] h
																WHERE	h.[job_id] = ''' + CAST(@jobID AS [nvarchar](36)) + N'''
																		AND h.[step_name] =''(Job outcome)''
																ORDER BY h.[instance_id] DESC
															)A
														), 0)
							AND h.[job_id] = ''' + CAST(@jobID AS [nvarchar](36)) + N'''
				)A'

SET @queryToRun = [dbo].[ufn_formatSQLQueryForLinkedServer](@sqlServerName, @queryToRun)

IF @debugMode=1	PRINT @queryToRun
INSERT	INTO #jobHistory([step_id], [step_name], [run_status], [run_date], [run_time], [duration], [message])
		EXEC (@queryToRun)

UPDATE #jobHistory	SET [message] = REPLACE([message], '&', '&amp;')
UPDATE #jobHistory	SET [message] = REPLACE([message], '<', '&lt;')
UPDATE #jobHistory	SET [message] = REPLACE([message], '>', '&gt;')
UPDATE #jobHistory	SET [message] = REPLACE([message], '"', '&quot;')
UPDATE #jobHistory	SET [message] = REPLACE([message], '&', '&amp;')
UPDATE #jobHistory	SET [message] = REPLACE([message], '''', '&apos;')


-----------------------------------------------------------------------------------------------------
SET @eventMessageData = '<job-history>'

SELECT @eventMessageData = @eventMessageData + [job_step_detail]
FROM (
		SELECT	'<job-step>' + 
				'<step_id>' + CAST([step_id] AS [varchar](32)) + '</step_id>' + 
				'<step_name>' + [step_name] + '</step_name>' + 
				'<run_status>' + [run_status] + '</run_status>' + 
				'<run_date>' + [run_date] + '</run_date>' + 
				'<run_time>' + [run_time] + '</run_time>' + 
				'<duration>' + [duration] + '</duration>' +
				'<message>' + [message] + '</message>' +
				'</job-step>' AS [job_step_detail] 
		FROM (
				SELECT	  [step_id]
						, [step_name]
						, [run_status]
						, [run_date]
						, [run_time]
						, [duration]
						, [message]
				FROM #jobHistory
			)x										
	)xmlData

SET @eventMessageData = @eventMessageData + '</job-history>'

IF @sendLogAsAttachment=0
	SET @logFileLocation = NULL


--if one of the job steps failed, will fail the job
DECLARE @failedSteps [int]

SELECT @failedSteps = COUNT(*)
FROM #jobHistory
WHERE [run_status] = 'Failed'

EXEC [dbo].[usp_logEventMessageAndSendEmail] @projectCode		= NULL,
											 @sqlServerName		= @sqlServerName,
											 @objectName		= @jobName,
											 @module			= @module,
											 @eventName			= 'sql agent job status',
											 @parameters		= @logFileLocation,
											 @eventMessage		= @eventMessageData,
											 @recipientsList	= NULL,
											 @eventType			= @eventType,
											 @additionalOption	= @failedSteps

IF @failedSteps <> 0
	begin
		SET @strMessage = 'Job execution failed. See individual steps status.'
		EXEC [dbo].[usp_logPrintMessage] @customMessage = @strMessage, @raiseErrorAsPrint = 1, @messagRootLevel = 0, @messageTreelevel = 0, @stopExecution=1
	end

GO

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
		@flgOptions			[int] = 2011,		/*  1 - use CHECKSUM (default)
													2 - use COMPRESSION, if available (default)
													4 - use COPY_ONLY
													8 - force change backup type (default): if log is set, and no database backup is found, a database backup will be first triggered
												  										    if diff is set, and no full database backup is found, a full database backup will be first triggered
												   16 - verify backup file (default)
											       32 - Stop execution if an error occurs. Default behaviour is to print error messages and continue execution
												   64 - create folders for each database (default)
												  128 - when performing cleanup, delete also orphans diff and log backups, when cleanup full database backups(default)
												  256 - for +2k5 versions, use xp_delete_file option
												  512 - skip databases involved in log shipping (primary or secondary or logs, secondary for full/diff backups) (default)
												 1024 - on alwayson availability groups, for secondary replicas, force copy-only backups (default)
												 2048 - change retention policy from RetentionDays to RetentionBackupsCount (number of full database backups to be kept)
													  - this may be forced by setting to true property 'Change retention policy from RetentionDays to RetentionBackupsCount'
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
			@eventData						[varchar](8000)

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
DECLARE @clusterName				[sysname],		
		@agName						[sysname],
		@agInstanceRoleDesc			[sysname],
		@agSynchronizationState		[sysname],
		@agPreferredBackupReplica	[bit]

/* AlwaysOn Availability Groups */
IF @serverVersionNum >= 11
	begin
		/* get cluster name */
		SET @queryToRun = N'SELECT [cluster_name] FROM sys.dm_hadr_cluster'
		SET @queryToRun = [dbo].[ufn_formatSQLQueryForLinkedServer](@sqlServerName, @queryToRun)

		SET @queryToRun = N'SELECT @clusterName = [cluster_name]
							FROM (' + @queryToRun + N')inq'

		SET @queryParameters = N'@clusterName [sysname] OUTPUT'
		IF @debugMode=1	EXEC [dbo].[usp_logPrintMessage] @customMessage = @queryToRun, @raiseErrorAsPrint = 0, @messagRootLevel = @executionLevel, @messageTreelevel = 1, @stopExecution=0

		EXEC sp_executesql @queryToRun, @queryParameters, @clusterName = @clusterName OUTPUT


		/* availability group configuration */
		SET @queryToRun = N'
					SELECT    ag.[name]
							, ars.[role_desc]
					FROM sys.availability_replicas ar
					INNER JOIN sys.dm_hadr_availability_replica_states ars ON ars.[replica_id]=ar.[replica_id] AND ars.[group_id]=ar.[group_id]
					INNER JOIN sys.availability_groups ag ON ag.[group_id]=ar.[group_id]
					INNER JOIN sys.dm_hadr_availability_replica_cluster_nodes arcn ON arcn.[group_name]=ag.[name] AND arcn.[replica_server_name]=ar.[replica_server_name]
					WHERE arcn.[replica_server_name] = ''' + @sqlServerName + N''''
		SET @queryToRun = [dbo].[ufn_formatSQLQueryForLinkedServer](@sqlServerName, @queryToRun)

		SET @queryToRun = N'SELECT    @agName = [name]
									, @agInstanceRoleDesc = [role_desc]
							FROM (' + @queryToRun + N')inq'
		SET @queryParameters = N'@agName [sysname] OUTPUT, @agInstanceRoleDesc [sysname] OUTPUT'
		IF @debugMode=1	EXEC [dbo].[usp_logPrintMessage] @customMessage = @queryToRun, @raiseErrorAsPrint = 0, @messagRootLevel = @executionLevel, @messageTreelevel = 1, @stopExecution=0

		EXEC sp_executesql @queryToRun, @queryParameters, @agName = @agName OUTPUT
														, @agInstanceRoleDesc = @agInstanceRoleDesc OUTPUT
	

		IF @agName IS NOT NULL AND @clusterName IS NOT NULL
			begin
				/* availability group synchronization status */
				SET @queryToRun = N'
						SELECT    hdrs.[synchronization_state_desc]
								, sys.fn_hadr_backup_is_preferred_replica(''' + @dbName + N''') AS [backup_is_preferred_replica]
						FROM sys.dm_hadr_database_replica_states hdrs
						INNER JOIN sys.availability_replicas ar ON ar.[replica_id]=hdrs.[replica_id]
						INNER JOIN sys.availability_databases_cluster adc ON adc.[group_id]=hdrs.[group_id] AND adc.[group_database_id]=hdrs.[group_database_id]
						INNER JOIN sys.dm_hadr_availability_replica_cluster_states rcs ON rcs.[replica_id]=ar.[replica_id] AND rcs.[group_id]=hdrs.[group_id]
						INNER JOIN sys.databases sd ON sd.name = adc.database_name
						WHERE	ar.[replica_server_name] = ''' + @sqlServerName + N'''
								AND adc.[database_name] = ''' + @dbName + N''''
				SET @queryToRun = [dbo].[ufn_formatSQLQueryForLinkedServer](@sqlServerName, @queryToRun)

				SET @queryToRun = N'SELECT    @agSynchronizationState = [synchronization_state_desc]
											, @agPreferredBackupReplica = [backup_is_preferred_replica]
									FROM (' + @queryToRun + N')inq'

				SET @queryParameters = N'@agSynchronizationState [sysname] OUTPUT, @agPreferredBackupReplica [bit] OUTPUT'
				IF @debugMode=1	EXEC [dbo].[usp_logPrintMessage] @customMessage = @queryToRun, @raiseErrorAsPrint = 0, @messagRootLevel = @executionLevel, @messageTreelevel = 1, @stopExecution=0

				EXEC sp_executesql @queryToRun, @queryParameters, @agSynchronizationState = @agSynchronizationState OUTPUT
																, @agPreferredBackupReplica = @agPreferredBackupReplica OUTPUT

				SET @agSynchronizationState = ISNULL(@agSynchronizationState, '')
				SET @agInstanceRoleDesc = ISNULL(@agInstanceRoleDesc, '')
	
				IF ISNULL(@agSynchronizationState, '')<>''
					begin
						IF UPPER(@agInstanceRoleDesc) NOT IN ('PRIMARY', 'SECONDARY')
							begin
								SET @queryToRun=N'Availability Group: Current role state [ ' + @agInstanceRoleDesc + N'] does not permit the backup operation.'
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

						/* allowed actions on a secondary replica */
						IF UPPER(@agInstanceRoleDesc) = 'SECONDARY'
							begin
								/* if instance is preferred replica */
								IF @agPreferredBackupReplica = 0
									begin
										SET @queryToRun=N'Availability Group: Current instance [ ' + @sqlServerName + N'] is not a backup preferred replica for the database [' + @dbName + N'].'
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

								/* copy-only full backups are allowed */
								IF @flgActions & 1 = 1 AND @flgOptions & 4 = 0
									begin
										/* on alwayson availability groups, for secondary replicas, force copy-only backups */
										IF @flgOptions & 1024 = 1024
											begin
												SET @queryToRun='Server is part of an Availability Group as a secondary replica. Forcing copy-only full backups.'
												EXEC [dbo].[usp_logPrintMessage] @customMessage = @queryToRun, @raiseErrorAsPrint = 0, @messagRootLevel = @executionLevel, @messageTreelevel = 1, @stopExecution=0
				
												SET @flgOptions = @flgOptions + 4
											end
										ELSE
											begin
												SET @queryToRun=N'Availability Group: Only copy-only full backups are allowed on a secondary replica.'
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

								/* Differential backups are not supported on secondary replicas. */
								IF @flgActions & 2 = 2
									begin
										SET @queryToRun=N'Availability Group: Differential backups are not supported on secondary replicas.'
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
				
								/* BACKUP LOG supports only regular log backups (the COPY_ONLY option is not supported for log backups on secondary replicas).*/
								IF @flgActions & 4 = 4 AND @flgOptions & 4 = 4
									begin
										SET @queryToRun=N'Availability Group: BACKUP LOG supports only regular log backups (the COPY_ONLY option is not supported for log backups on secondary replicas).'
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

								/* To back up a secondary database, a secondary replica must be able to communicate with the primary replica and must be SYNCHRONIZED or SYNCHRONIZING. */
								IF UPPER(@agSynchronizationState) NOT IN ('SYNCHRONIZED', 'SYNCHRONIZING')
									begin
										SET @queryToRun=N'Availability Group: Current secondary replica state [ ' + @agSynchronizationState + N'] does not permit the backup operation.'
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

						SET @agName = @clusterName + '_' + @agName
					end
				ELSE
					SET @agName=NULL
			end
		ELSE 
			SET @agName=NULL
	end

																				
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
SET @backupLocation = @backupLocation + @sqlServerName + '\' + CASE WHEN @flgOptions & 64 = 64 THEN @dbName + '\' ELSE '' END

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

--check if another backup is needed (full)
SET @optionForceChangeBackupType=0
IF @flgOptions & 8 = 8
	begin
		--check for any full database backup (when differential should be made) or any full/incremental database backup (when transaction log should be made)
		IF @flgActions & 2 = 2 OR @flgActions & 4 = 4
			begin
				SET @queryToRun = N''
				SET @queryToRun = @queryToRun + 'SELECT COUNT(*) FROM msdb.dbo.backupset WHERE [database_name]=''' + @dbName + N''' AND [type] IN (''D''' + CASE WHEN @flgActions & 4 = 4 THEN N', ''I''' ELSE N'' END + N')'
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

		SET @queryToRun	= N'BACKUP DATABASE ['+ @dbName + N'] TO DISK = ''' + @backupLocation + @backupFileName + N''' WITH STATS = 10, NAME = ''' + @backupFileName + N'''' + @backupOptions
		--IF @debugMode=1	
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

--IF @debugMode=1	
	EXEC [dbo].[usp_logPrintMessage] @customMessage = @queryToRun, @raiseErrorAsPrint = 1, @messagRootLevel = @executionLevel, @messageTreelevel = 1, @stopExecution=0	
EXEC @errorCode = [dbo].[usp_sqlExecuteAndLog]	@sqlServerName	= @sqlServerName,
												@dbName			= @dbName,
												@module			= 'dbo.usp_mpDatabaseBackup',
												@eventName		= 'database backup',
												@queryToRun  	= @queryToRun,
												@flgOptions		= @flgOptions,
												@executionLevel	= @nestedExecutionLevel,
												@debugMode		= @debugMode

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
