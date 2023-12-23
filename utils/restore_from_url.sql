USE msdb;

IF NOT EXISTS (SELECT * FROM sys.tables WHERE name = 'restore_execution_history')
	CREATE TABLE dbo.restore_execution_history
	(
		restore_execution_id BIGINT NOT NULL PRIMARY KEY IDENTITY(1, 1),
		database_name NVARCHAR(128) NOT NULL,
		url NVARCHAR(MAX) NOT NULL,
		with_recovery BIT NOT NULL,
		restore_command NVARCHAR(MAX),
		error NVARCHAR(MAX),
		restore_execution_begin DATETIME NOT NULL DEFAULT GETDATE(),
		restore_database_begin DATETIME NULL,
		restore_execution_end DATETIME
	);

GO

CREATE OR ALTER PROCEDURE restore_from_url
	@database_name NVARCHAR(128) = 'MasterData', 
	@url NVARCHAR(MAX) = N's3://',
	@with_recovery BIT = 0
AS
BEGIN
	SET NOCOUNT ON;
	SET DEADLOCK_PRIORITY LOW;
	SET TRAN ISOLATION LEVEL READ UNCOMMITTED;

	INSERT INTO dbo.restore_execution_history(database_name, url, with_recovery)	VALUES (@database_name, @url, @with_recovery);
	DECLARE @restore_execution_id BIGINT = @@IDENTITY;

	DECLARE @error NVARCHAR(max);

	/* WITH templates */
	DECLARE @move_tpl NVARCHAR(MAX) = ', MOVE ''@LogicalName'' TO ''@PhysicalName'''
	/* WITH */
	DECLARE @recovery NVARCHAR(10) = CASE @with_recovery WHEN 0 THEN 'NORECOVERY' ELSE 'RECOVERY' END;
	DECLARE @move NVARCHAR(MAX) = '';

	/* RESTORE commands */
	DECLARE @restore_database_tpl NVARCHAR(MAX) = 'RESTORE DATABASE [@database_name] FROM URL = ''@url'' WITH @recovery @move';

	DECLARE @restore_headeronly NVARCHAR(MAX) = REPLACE('RESTORE HEADERONLY FROM URL = ''@url''', '@url', @url);
	DECLARE @restore_filelistonly NVARCHAR(MAX) = REPLACE('RESTORE FILELISTONLY FROM URL = ''@url''', '@url', @url);
	DECLARE @restore_database NVARCHAR(MAX);

	DECLARE @instance_data_path NVARCHAR(256) =  CONVERT(NVARCHAR(256), SERVERPROPERTY('InstanceDefaultDataPath')) 
	DECLARE @instance_logs_path NVARCHAR(256) =  CONVERT(NVARCHAR(256), SERVERPROPERTY('InstanceDefaultLogPath')) 

	/* free space on drive where data files should be placed */
	DECLARE @data_free_space BIGINT = (SELECT free_space_in_bytes FROM sys.dm_os_enumerate_fixed_drives WHERE @instance_data_path LIKE fixed_drive_path + '%');

	/* free space on drive where logs files should be placed */
	DECLARE @logs_free_space BIGINT = (SELECT free_space_in_bytes FROM sys.dm_os_enumerate_fixed_drives WHERE @instance_data_path LIKE fixed_drive_path + '%');

	/* size of database data files */
	DECLARE @db_data_size BIGINT;
	/* size of database tlog files */
	DECLARE @db_logs_size BIGINT;

	/* RESTORE HEADERONLY resultset  
	--DECLARE @backup_header TABLE
	--(
	--	BackupName NVARCHAR(128),
	--	BackupDescription NVARCHAR(255),
	--	BackupType SMALLINT,
	--	ExpirationDate DATETIME,
	--	Compressed BIT,
	--	Position SMALLINT,
	--	DeviceType TINYINT,
	--	UserName NVARCHAR(128),
	--	ServerName NVARCHAR(128),
	--	DatabaseName NVARCHAR(128),
	--	DatabaseVersion INT,
	--	DatabaseCreationDate DATETIME,
	--	BackupSize NUMERIC(20, 0),
	--	FirstLSN NUMERIC(25, 0),
	--	LastLSN NUMERIC(25, 0),
	--	CheckpointLSN NUMERIC(25, 0),
	--	DatabaseBackupLSN NUMERIC(25, 0),
	--	BackupStartDate DATETIME,
	--	BackupFinishDate DATETIME,
	--	SortOrder SMALLINT,
	--	CodePage SMALLINT,
	--	UnicodeLocaleId INT,
	--	UnicodeComparisonStyle INT,
	--	CompatibilityLevel TINYINT,
	--	SoftwareVendorId INT,
	--	SoftwareVersionMajor INT,
	--	SoftwareVersionMinor INT,
	--	SoftwareVersionBuild INT,
	--	MachineName NVARCHAR(128),
	--	Flags INT,
	--	BindingID UNIQUEIDENTIFIER,
	--	RecoveryForkID UNIQUEIDENTIFIER,
	--	Collation NVARCHAR(128),
	--	FamilyGUID UNIQUEIDENTIFIER,
	--	HasBulkLoggedData BIT,
	--	IsSnapshot BIT,
	--	IsReadOnly BIT,
	--	IsSingleUser BIT,
	--	HasBackupChecksums BIT,
	--	IsDamaged BIT,
	--	BeginsLogChain BIT,
	--	HasIncompleteMetaData BIT,
	--	IsForceOffline BIT,
	--	IsCopyOnly BIT,
	--	FirstRecoveryForkID UNIQUEIDENTIFIER,
	--	ForkPointLSN NUMERIC(25, 0),
	--	RecoveryModel NVARCHAR(60),
	--	DifferentialBaseLSN NUMERIC(25, 0),
	--	DifferentialBaseGUID UNIQUEIDENTIFIER,
	--	BackupTypeDescription NVARCHAR(60),
	--	BackupSetGUID UNIQUEIDENTIFIER,
	--	CompressedBackupSize BIGINT,
	--	containment TINYINT,
	--	KeyAlgorithm NVARCHAR(32),
	--	EncryptorThumbprint VARBINARY(20),
	--	EncryptorType NVARCHAR(32),
	--	LastValidRestoreTime DATETIME,
	--	TimeZone NVARCHAR(32),
	--	CompressionAlgorithm NVARCHAR(32)
	--);
	*/


	/* RESTORE FILELISTONLY resultset */
	DECLARE @file_list TABLE
	(
		LogicalName NVARCHAR(128),
		PhysicalName NVARCHAR(260),
		Type CHAR(1),
		FileGroupName NVARCHAR(128) NULL,
		Size NUMERIC(20, 0),
		MaxSize NUMERIC(20, 0),
		FileID BIGINT,
		CreateLSN NUMERIC(25, 0),
		DropLSN NUMERIC(25, 0) NULL,
		UniqueID UNIQUEIDENTIFIER,
		ReadOnlyLSN NUMERIC(25, 0) NULL,
		ReadWriteLSN NUMERIC(25, 0) NULL,
		BackupSizeInBytes BIGINT,
		SourceBlockSize INT,
		FileGroupID INT,
		LogGroupGUID UNIQUEIDENTIFIER NULL,
		DifferentialBaseLSN NUMERIC(25, 0) NULL,
		DifferentialBaseGUID UNIQUEIDENTIFIER NULL,
		IsReadOnly BIT,
		IsPresent BIT,
		TDEThumbprint VARBINARY(32) NULL,
		SnapshotURL NVARCHAR(360) NULL
	);

	IF EXISTS(SELECT * FROM sys.databases WHERE name = @database_name) 
	BEGIN
		SET @error = 'Database already exists';
		UPDATE dbo.restore_execution_history SET error = @error WHERE restore_execution_id = @restore_execution_id
		RAISERROR(@error, 16, 1)
	END

	/* restoring HEADERONLY */
	--INSERT @backup_header(BackupName, BackupDescription, BackupType, ExpirationDate, Compressed, Position, DeviceType, UserName, ServerName, DatabaseName, DatabaseVersion, DatabaseCreationDate, BackupSize, FirstLSN, LastLSN,
	--	CheckpointLSN, DatabaseBackupLSN, BackupStartDate, BackupFinishDate, SortOrder, CodePage, UnicodeLocaleId, UnicodeComparisonStyle, CompatibilityLevel, SoftwareVendorId, SoftwareVersionMajor, SoftwareVersionMinor, SoftwareVersionBuild,
	--	MachineName, Flags, BindingID, RecoveryForkID, Collation, FamilyGUID, HasBulkLoggedData, IsSnapshot, IsReadOnly, IsSingleUser, HasBackupChecksums, IsDamaged, BeginsLogChain, HasIncompleteMetaData, IsForceOffline, IsCopyOnly,
	--	FirstRecoveryForkID, ForkPointLSN, RecoveryModel, DifferentialBaseLSN, DifferentialBaseGUID, BackupTypeDescription, BackupSetGUID, CompressedBackupSize, containment, KeyAlgorithm, EncryptorThumbprint, EncryptorType, LastValidRestoreTime,
	--	TimeZone, CompressionAlgorithm)
	--EXEC(@restore_headeronly);

	/* restoring FILELISTONLY */
	INSERT @file_list(LogicalName, PhysicalName, Type, FileGroupName, Size, MaxSize, FileID, CreateLSN, DropLSN, UniqueID, ReadOnlyLSN, ReadWriteLSN, BackupSizeInBytes, SourceBlockSize, FileGroupID, LogGroupGUID, DifferentialBaseLSN,DifferentialBaseGUID, IsReadOnly, IsPresent, TDEThumbprint, SnapshotURL)
	EXEC(@restore_filelistonly);
	
	/* checking for available space	*/
	SELECT @db_data_size = SUM(Size) FROM @file_list WHERE Type <> 'L';
	SELECT @db_logs_size = SUM(Size) FROM @file_list WHERE Type = 'L';

	IF @data_free_space - @db_data_size < 0
	BEGIN
		SET @error = 'Not enough space for data';
		UPDATE dbo.restore_execution_history SET error = @error WHERE restore_execution_id = @restore_execution_id
		RAISERROR(@error, 16, 1)
	END

	IF @logs_free_space - @db_logs_size < 0
	BEGIN
		SET @error = 'Not enough space for data';
		UPDATE dbo.restore_execution_history SET error = @error WHERE restore_execution_id = @restore_execution_id
		RAISERROR(@error, 16, 1)
	END

	/* preparing WITH MOVE statetment */
	SELECT @move = CONCAT(@move, REPLACE(REPLACE(@move_tpl, '@LogicalName', LogicalName), '@PhysicalName', 
	CASE FileID
		WHEN 1 THEN CONCAT(@instance_data_path,'\',LogicalName,'.mdf')
		WHEN 2 THEN CONCAT(@instance_logs_path,'\',LogicalName,'.ldf')
		ELSE 
		CASE Type 
			WHEN 'D' THEN CONCAT(@instance_data_path,'\',LogicalName,'.ndf')
			ELSE CONCAT(@instance_data_path,'\',LogicalName)
		END
	END
	)) FROM @file_list;

	SET @restore_database = REPLACE(REPLACE(REPLACE(REPLACE(@restore_database_tpl,'@database_name',@database_name), '@url', @url), '@recovery', @recovery), '@move', @move);
	
	UPDATE dbo.restore_execution_history	
	SET 
		restore_database_begin = GETDATE(), 
		restore_command = @restore_database
	WHERE restore_execution_id = @restore_execution_id;
	
	EXEC(@restore_database)

	UPDATE dbo.restore_execution_history	SET restore_execution_end = GETDATE()	WHERE restore_execution_id = @restore_execution_id;
END;


