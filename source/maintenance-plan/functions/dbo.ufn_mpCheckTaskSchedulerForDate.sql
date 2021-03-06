RAISERROR('Create function: [dbo].[ufn_mpCheckTaskSchedulerForDate]', 10, 1) WITH NOWAIT
GO
IF  EXISTS (SELECT * FROM sysobjects WHERE id = OBJECT_ID(N'[dbo].[ufn_mpCheckTaskSchedulerForDate]') AND xtype in (N'FN', N'IF', N'TF', N'FS', N'FT'))
DROP FUNCTION [dbo].[ufn_mpCheckTaskSchedulerForDate]
GO

CREATE FUNCTION [dbo].[ufn_mpCheckTaskSchedulerForDate]
(		
	@projectCode			[varchar](32)=NULL,
	@jobDescriptor			[varchar](256),
	@taskName				[varchar](256),
	@runDate				[datetime]
)
RETURNS [bit]
/* WITH ENCRYPTION */
AS

-- ============================================================================
-- Copyright (c) 2004-2016 Dan Andrei STEFAN (danandrei.stefan@gmail.com)
-- ============================================================================
-- Author			 : Dan Andrei STEFAN
-- Create date		 : 26.10.2016
-- Module			 : Database Analysis & Performance Monitoring
-- ============================================================================

begin
	DECLARE   @scheduledWeekday		[varchar](16)
			, @taskCanRun			[bit]
			, @useDefaultScheduler	[bit]

	SET @taskCanRun = 0

	------------------------------------------------------------------------------------------------------------------------------------------
	--get default project code
	IF @projectCode IS NULL
		SELECT	@projectCode = [value]
		FROM	[dbo].[appConfigurations]
		WHERE	[name] = 'Default project code'
				AND [module] = 'common'

	------------------------------------------------------------------------------------------------------------------------------------------
	--get property for using default scheduler or not
	SELECT @useDefaultScheduler =  [value]
	FROM	[dbo].[appConfigurations]
	WHERE	[name] = 'Use Default Scheduler for maintenance tasks if project specific not defined'
			AND [module] = 'maintenance-plan'

	SET @useDefaultScheduler = ISNULL(@useDefaultScheduler, 1)

	------------------------------------------------------------------------------------------------------------------------------------------
	SELECT @scheduledWeekday = [scheduled_weekday]
	FROM [maintenance-plan].[vw_internalScheduler]
	WHERE	[project_code] = @projectCode
			AND [job_descriptor] = @jobDescriptor
			AND [task_name] = @taskName
			AND [active] = 1

	--get  default schedule, if a particular one was not defined
	IF	@useDefaultScheduler = 1 
		AND @scheduledWeekday IS NULL 
		AND EXISTS (SELECT * FROM [maintenance-plan].[vw_internalScheduler] WHERE ([project_code] = 'DEFAULT' OR [project_code] IS NULL))
			SELECT @scheduledWeekday = [scheduled_weekday]
			FROM [maintenance-plan].[vw_internalScheduler]
			WHERE	([project_code] = 'DEFAULT' OR [project_code] IS NULL)
					AND [job_descriptor] = @jobDescriptor
					AND [task_name] = @taskName
					AND [active] = 1

	IF @scheduledWeekday IS NOT NULL AND @scheduledWeekday IN ('Daily', DATENAME(weekday, @runDate))
		SET @taskCanRun = 1
	
	RETURN @taskCanRun
end
GO
