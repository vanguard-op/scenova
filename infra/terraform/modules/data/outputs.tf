output "db_connection_name" {
  value = google_sql_database_instance.primary.connection_name
}
output "db_private_ip" {
  value = google_sql_database_instance.primary.private_ip_address
}
output "db_name" {
  value = google_sql_database.primary.name
}
output "redis_host" {
  value = google_redis_instance.cache.host
}
output "redis_port" {
  value = google_redis_instance.cache.port
}
output "bucket_name" {
  value = google_storage_bucket.clips.name
}
output "bucket_url" {
  value = google_storage_bucket.clips.url
}
