provider "google" {
  project = "tranquil-harbor-366108"
  region = "asia-southeast2"
}
#Backend
terraform {
  backend "gcs"{
    bucket = "my-state-staging"
    prefix = "terraform/state"
  }
  required_providers {
    google = {
      source = "hashicorp/google"
      version = "~> 4.0"
    }
  }
}
#Enable API
resource "google_project_service" "compute" {
  service = "compute.googleapis.com"
}
resource "google_project_service" "container" {
  service = "container.googleapis.com"
}
#VPC
resource "google_compute_network" "network" {
  name = "network"
  routing_mode = "REGIONAL"
  auto_create_subnetworks = false
  mtu = 1460
  delete_default_routes_on_create = false

  depends_on = [
    google_project_service.compute,
    google_project_service.container
  ]

}

#Subnet
resource "google_compute_subnetwork" "private" {
  name = "private"
  ip_cidr_range = "10.100.0.0/18"
  network = google_compute_network.network.id
  region = "asia-southeast2"
  private_ip_google_access = true
 
  secondary_ip_range = [{
    ip_cidr_range = "10.48.0.0/14"
    range_name = "pod-range"
  },
  {
    ip_cidr_range = "10.52.0.0/20"
    range_name = "service-range"
  }]
}
#Route
resource "google_compute_router" "router" {
  name = "router"
  region = "asia-southeast2"
  network = google_compute_network.network.id
}
#NAT
resource "google_compute_router_nat" "nat" {
  name                               = "nat"
  router                             = google_compute_router.router.name
  region                             = google_compute_router.router.region

  nat_ip_allocate_option             = "MANUAL_ONLY"
  source_subnetwork_ip_ranges_to_nat = "LIST_OF_SUBNETWORKS"

  subnetwork {
    name = google_compute_subnetwork.private.id
    source_ip_ranges_to_nat = ["ALL_IP_RANGES"]
  }

  nat_ips = [google_compute_address.nat.self_link]
}
#External Address
resource "google_compute_address" "nat" {
  name = "nat"
  address_type = "EXTERNAL"
  network_tier = "PREMIUM"

  depends_on = [
    google_project_service.compute
  ]
}
#Firewall
resource "google_compute_firewall" "allow_ssh" {
  name = "allow-ssh"
  network = google_compute_network.network.id

  allow {
    protocol = "tcp"
    ports = ["22"]
  }

  source_ranges = [ "0.0.0.0/0" ]
}
#GKE
resource "google_container_cluster" "primary" {
  name = "primary"
  location = "asia-southeast2-b"
  remove_default_node_pool = true
  initial_node_count = 1
  network = google_compute_network.network.self_link
  subnetwork = google_compute_subnetwork.private.self_link
  logging_service = "logging.googleapis.com/kubernetes"

  addons_config {
    http_load_balancing {
      disabled = true
    }
    horizontal_pod_autoscaling {
      disabled = false
    }
  }

  release_channel {
    channel = "REGULAR"
  }

  workload_identity_config {
    workload_pool = "tranquil-harbor-366108.svc.id.goog"
  }

  ip_allocation_policy {
    cluster_secondary_range_name = "pod-range"
    services_secondary_range_name = "service-range"
  }

  private_cluster_config {
    enable_private_nodes = true
    enable_private_endpoint = false
    master_ipv4_cidr_block = "172.16.0.0/28"
  }
}

#Node gruop
resource "google_service_account" "kubernetes" {
  account_id = "kubernetes"
}

resource "google_container_node_pool" "general" {
  name = "general"
  cluster = google_container_cluster.primary.id
  node_count = 2

  management {
    auto_repair = true
    auto_upgrade = true
  }

  node_config {
    preemptible = false
    machine_type = "e2-small"

    labels = {
      role = "general"
    }

    service_account = google_service_account.kubernetes.email
    oauth_scopes = [ "https://www.googleapis.com/auth/cloud-platform" ]
  }
}

resource "google_container_node_pool" "spot" {
  name = "spot"
  cluster = google_container_cluster.primary.id

  management {
    auto_repair = true
    auto_upgrade = true
  }

  autoscaling {
    max_node_count = 10
    min_node_count = 0
  }

  node_config {
    preemptible = true
    machine_type = "e2-small"

    labels = {
      "team" = "devops"
    }

    taint {
      key = "instance_type"
      value = "spot"
      effect = "NO_SCHEDULE"
    }

    service_account = google_service_account.kubernetes.email
    oauth_scopes = [ "https://www.googleapis.com/auth/cloud-platform" ]
  }
}

resource "google_compute_instance" "test" {
  name         = "test"
  machine_type = "e2-micro"
  zone = "asia-southeast2-a"
  boot_disk {
    initialize_params {
      image = "ubuntu-os-cloud/ubuntu-2004-lts"
      labels = {
        my_label = "ubuntu"
      }
    }
  }
    network_interface {
      network = google_compute_network.network.id
      subnetwork = google_compute_subnetwork.private.id
      access_config {
    }
  }
}
