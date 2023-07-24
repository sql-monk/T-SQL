/* export configuraton */
DECLARE @export_schemas NVARCHAR(MAX) = NULL;
-- N'AGGREGATE_FUNCTION, CHECK_CONSTRAINT, CLR_SCALAR_FUNCTION, CLR_STORED_PROCEDURE, CLR_TABLE_VALUED_FUNCTION, CLR_TRIGGER, DEFAULT_CONSTRAINT, EDGE_CONSTRAINT, EXTENDED_STORED_PROCEDURE, FOREIGN_KEY_CONSTRAINT, INTERNAL_TABLE, PLAN_GUIDE, PRIMARY_KEY_CONSTRAINT, REPLICATION_FILTER_PROCEDURE, RULE, SEQUENCE_OBJECT, SERVICE_QUEUE, SQL_INLINE_TABLE_VALUED_FUNCTION, SQL_SCALAR_FUNCTION, SQL_STORED_PROCEDURE, SQL_TABLE_VALUED_FUNCTION, SQL_TRIGGER, SYNONYM, SYSTEM_TABLE, TYPE_TABLE, UNIQUE_CONSTRAINT, USER_TABLE, VIEW';
DECLARE @export_objects NVARCHAR(MAX) = N'USER_TABLE, VIEW,AGGREGATE_FUNCTION, SQL_INLINE_TABLE_VALUED_FUNCTION, SQL_SCALAR_FUNCTION, SQL_STORED_PROCEDURE, SQL_TABLE_VALUED_FUNCTION, SQL_TRIGGER, USER_TABLE, VIEW';
DECLARE @skip_schemas NVARCHAR(MAX) = NULL;
DECLARE @skip_objects NVARCHAR(MAX) = NULL;

DECLARE @result TABLE(md NVARCHAR(MAX), md_path NVARCHAR(260) PRIMARY KEY);

SET NOCOUNT ON;
SET TRAN ISOLATION LEVEL READ UNCOMMITTED;

/* string templates */
DECLARE @md_params_header NVARCHAR(MAX) = N'
## Параметри
|параметр    |тип      |описання     |
|------------|---------|-------------|
';
DECLARE @md_columns_header NVARCHAR(MAX) = N'
## Cтовпці
|назва       |тип      |описання     |
|------------|---------|-------------|
';
DECLARE @md_referenced_header NVARCHAR(MAX) = N'
## Залежить від
';
DECLARE @md_referencing_header NVARCHAR(MAX) = N'
## Залежні об''єкти
';
DECLARE @md_params_tpl NVARCHAR(MAX) = N'|#param#      |#type#    |#description# |
';
DECLARE @md_columns_tpl NVARCHAR(MAX) = N'|#field#      |#type#    |#description# |
';
DECLARE @md_ref_tpl NVARCHAR(MAX) = N'*  [#full_obj_name#](../#type#/#full_obj_name#.md)
';
DECLARE @definition_tpl NVARCHAR(MAX) = N'
## Визначення
```sql
#definition#
```';

DECLARE @md_tpl NVARCHAR(MAX) = N'# #sch_name#.#obj_name#
#returntype#
#description#
#params#
#columns#
#referenced#
#referencing#
#definition#
---
';

DECLARE
	@object_id INT,
	@sch_name NVARCHAR(128),
	@obj_name NVARCHAR(128),
	@type NVARCHAR(60);
DECLARE mcur CURSOR STATIC LOCAL FORWARD_ONLY READ_ONLY FOR
SELECT
	o.object_id,
	SCHEMA_NAME(o.schema_id),
	o.name,
	o.type_desc
FROM	sys.objects o
WHERE o.is_ms_shipped = 0
			AND (@export_schemas IS NULL OR LEN(TRIM(@export_schemas)) = 0 OR SCHEMA_NAME(o.schema_id)IN(SELECT TRIM(value)FROM STRING_SPLIT(@export_schemas, ',')))
			AND (@skip_schemas IS NULL OR LEN(TRIM(@skip_schemas)) = 0 OR SCHEMA_NAME(o.schema_id) NOT IN(SELECT TRIM(value)FROM STRING_SPLIT(@skip_schemas, ',')))
			AND (@export_objects IS NULL OR LEN(TRIM(@export_objects)) = 0 OR o.type_desc IN(SELECT TRIM(value)FROM STRING_SPLIT(@export_objects, ',')))
			AND (@skip_objects IS NULL OR LEN(TRIM(@skip_objects)) = 0 OR o.type_desc NOT IN(SELECT TRIM(value)FROM STRING_SPLIT(@skip_objects, ',')));
OPEN mcur;

FETCH NEXT FROM mcur
INTO
	@object_id,
	@sch_name,
	@obj_name,
	@type;
WHILE @@FETCH_STATUS = 0
BEGIN
	DECLARE @md NVARCHAR(MAX) = REPLACE(REPLACE(@md_tpl, '#sch_name#', @sch_name), '#obj_name#', @obj_name);

	-- description
	DECLARE @descrption NVARCHAR(MAX) = (SELECT CONVERT(NVARCHAR(MAX), value)FROM sys.extended_properties WHERE major_id = @object_id AND class = 1 AND name = 'MS_Description');
	SET @md = REPLACE(@md, '#description#', ISNULL(@descrption, ''));

	-- definition
	DECLARE @definition NVARCHAR(MAX) = (SELECT definition FROM sys.sql_modules WHERE object_id = @object_id);
	SET @md = REPLACE(@md, '#definition#', ISNULL(REPLACE(@definition_tpl, '#definition#', @definition), ''));

	-- params
	DECLARE @params NVARCHAR(MAX) = NULL;
	SELECT	@params = CONCAT(@params, a.params)
	FROM(
		SELECT	REPLACE(REPLACE(REPLACE(@md_params_tpl, '#param#', params.name), '#type#', t.name), '#description#', ISNULL(CONVERT(NVARCHAR(MAX), ep.value), '')) params
		FROM	sys.parameters params
			JOIN sys.types t ON t.user_type_id = params.user_type_id
			LEFT JOIN sys.extended_properties ep ON ep.major_id = params.object_id AND ep.minor_id = params.parameter_id AND ep.class = 2 AND ep.name = 'MS_Description'
		WHERE params.object_id = @object_id AND params.parameter_id > 0
	) a;
	SET @params = @md_params_header + @params;
	SET @md = REPLACE(@md, '#params#', ISNULL(@params, ''));

	-- return type
	DECLARE @returntype NVARCHAR(128) = NULL;
	SELECT @returntype = t.name FROM sys.types t JOIN sys.parameters p ON p.user_type_id = t.user_type_id AND p.object_id = @object_id AND p.parameter_id = 0;
	SET @md = REPLACE(@md, '#returntype#', ISNULL(@returntype, ''));

	-- columns
	DECLARE @columns NVARCHAR(MAX) = NULL;
	SELECT	@columns = CONCAT(@columns, a.cols)
	FROM(
		SELECT DISTINCT
			REPLACE(REPLACE(REPLACE(@md_params_tpl, '#param#', col.name), '#type#', t.name), '#description#', ISNULL(CONVERT(NVARCHAR(MAX), ep.value), '')) cols
		FROM	sys.columns col
			JOIN sys.types t ON t.user_type_id = col.user_type_id
			LEFT JOIN sys.extended_properties ep ON ep.major_id = col.object_id AND ep.minor_id = col.column_id AND ep.class = 1 AND ep.name = 'MS_Description'
		WHERE col.object_id = @object_id
	) a;
	--PRINT @columns;
	SET @columns = @md_columns_header + @columns;
	SET @md = REPLACE(@md, '#columns#', ISNULL(@columns, ''));

	-- referenced
	DECLARE @referenced NVARCHAR(MAX) = NULL;
	SELECT	@referenced = CONCAT(@referenced, a.referenced)
	FROM(
		SELECT DISTINCT
			REPLACE(REPLACE(@md_ref_tpl, '#full_obj_name#', CONCAT((re.referenced_server_name + '.'), (re.referenced_database_name + '.'), (re.referenced_schema_name), '.', (re.referenced_entity_name))), '#type#', ISNULL(o.type_desc COLLATE DATABASE_DEFAULT, '#')) referenced
		FROM	sys.dm_sql_referenced_entities(@sch_name + '.' + @obj_name, DEFAULT) re
			LEFT JOIN sys.objects o ON o.object_id = OBJECT_ID(CONCAT((re.referenced_server_name + '.'), (re.referenced_database_name + '.'), (re.referenced_schema_name), '.', (re.referenced_entity_name)))
		WHERE o.object_id <> @object_id
	) a;
	SET @referenced = @md_referenced_header + @referenced;
	SET @md = REPLACE(@md, '#referenced#', ISNULL(@referenced, ''));

	-- referencing
	DECLARE @referencing NVARCHAR(MAX) = NULL;
	SELECT	@referencing = CONCAT(@referencing, a.referencing)
	FROM(
		SELECT DISTINCT
			REPLACE(REPLACE(@md_ref_tpl, '#full_obj_name#', CONCAT((re.referencing_schema_name), '.', (re.referencing_entity_name))), '#type#', ISNULL(o.type_desc COLLATE DATABASE_DEFAULT, '#')) referencing
		FROM	sys.dm_sql_referencing_entities(@sch_name + '.' + @obj_name, 'object') re
			LEFT JOIN sys.objects o ON o.object_id = OBJECT_ID(CONCAT((re.referencing_schema_name), '.', (re.referencing_entity_name)))
	) a;
	PRINT @referencing;
	SET @referencing = @md_referencing_header + @referencing;
	SET @md = REPLACE(@md, '#referencing#', ISNULL(@referencing, ''));


	INSERT @result(md, md_path)SELECT		@md, CONCAT(@type, '/', @sch_name, '.', @obj_name, '.md');

	FETCH NEXT FROM mcur
	INTO
		@object_id,
		@sch_name,
		@obj_name,
		@type;
END;
CLOSE mcur;
DEALLOCATE mcur;

SELECT * FROM		@result;