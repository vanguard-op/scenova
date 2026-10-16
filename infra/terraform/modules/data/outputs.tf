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
  # Empty when Redis is not part of the shape (var.enable_redis = false).
  value = try(google_redis_instance.cache[0].host, "")
}
output "redis_port" {
  value = try(google_redis_instance.cache[0].port, 0)
}
output "bucket_name" {
  value = google_storage_bucket.clips.name
}
output "bucket_url" {
  value = google_storage_bucket.clips.url
}
