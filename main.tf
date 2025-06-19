terraform {
  required_providers {
    opennebula = {
      source  = "OpenNebula/opennebula"
      version = "1.5.0"
    }
  }
}

variable "endpoint" {
  type    = string
  default = "http://10.2.11.40:2633/RPC2"
}
variable "username" {
  type    = string
  default = "oneadmin"
}
variable "password" {
  type    = string
  default = "asd"
}

provider "opennebula" {
  endpoint = var.endpoint
  username = var.username
  password = var.password
}

resource "random_id" "hydra-ci" {
  byte_length = 4
}

data "opennebula_virtual_network" "hydra-ci" {
  for_each = { service = null }
  name     = each.key
}

resource "opennebula_image" "hydra-ci" {
  for_each     = { nixos = "https://d24fmfybwxpuhu.cloudfront.net/nixos-25.05.803297.10d7f8d34e5e-20250609.qcow2" }
  name         = "hydra-ci-${each.key}-${random_id.hydra-ci.id}"
  datastore_id = "1"
  persistent   = false
  permissions  = "642"
  dev_prefix   = "vd"
  driver       = "qcow2"
  path         = each.value
}

locals {
  user_data = {
    hydra = {
      write_files = [
        {
          path        = "/var/tmp/setup-hydra-ci.sh"
          owner       = "root:root"
          permissions = "u=rwx,go=rx"
          encoding    = "b64"
          content     = base64encode(file("${path.module}/setup-hydra-ci.sh"))
        },
      ]
      runcmd = [
        "/run/current-system/sw/bin/bash --login /var/tmp/setup-hydra-ci.sh",
      ]
    }
  }
}

resource "opennebula_virtual_machine" "hydra-ci" {
  for_each    = { hydra = opennebula_image.hydra-ci["nixos"].id }
  name        = "hydra-ci-${each.key}-${random_id.hydra-ci.id}"
  permissions = "642"
  cpu         = "1"
  vcpu        = "2"
  memory      = 16 * 1024

  context = {
    SET_HOSTNAME       = "hydra-ci"
    NETWORK            = "YES"
    TOKEN              = "YES"
    SSH_PUBLIC_KEY     = "$USER[SSH_PUBLIC_KEY]"
    USER_DATA_ENCODING = "base64"
    USER_DATA          = base64encode(join("\n", ["#cloud-config", yamlencode(local.user_data[each.key])]))
  }

  os {
    arch = "x86_64"
    boot = ""
  }

  disk {
    image_id = each.value
    size     = 64 * 1024
  }

  nic {
    network_id = data.opennebula_virtual_network.hydra-ci["service"].id
  }

  graphics {
    keymap = "en-us"
    listen = "0.0.0.0"
    type   = "VNC"
  }
}
