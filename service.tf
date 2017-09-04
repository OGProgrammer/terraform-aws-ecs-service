data "template_file" "service_task" {
  template = "${file("${path.module}/service.json")}"

  vars = {
    env_name = "${var.env_name}"
    region = "${var.region}"
    app_name = "${var.app_name}"
    image_name = "${var.image_name}"
    docker_tag = "${var.docker_tag}"
    max_memory = "${var.max_memory}"
    reserved_memory = "${var.reserved_memory}"
  }
}
