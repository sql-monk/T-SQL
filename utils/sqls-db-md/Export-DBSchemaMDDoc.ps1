Import-Module dbatools

$SqlInstance = "servername"
$Database = "dbname"

$path = Split-Path -Parent $PSCommandPath;

$queries = @{
  generate_md_doc_en = (Get-Content "$path\generate-md-doc-en.sql" -Raw);
  generate_md_doc_ua = (Get-Content "$path\generate-md-doc-ua.sql" -Raw);
};

Invoke-DbaQuery -SqlInstance $SqlInstance -Database $Database -Query $queries.generate_md_doc_en | ForEach-Object {
  $full_path = $path + "/" + $_.md_path;
  $save_path = Split-Path $full_path;
  
  if (-Not (Test-Path $save_path)) {
    New-Item -Path $save_path -ItemType Directory 
  }
  $_.md | Out-File -FilePath $full_path -Force 
}
