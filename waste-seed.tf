resource "azurerm_virtual_network" "project_vnet" {
  name                = "vnet-cost-governance-waste-detection"
  address_space       = ["10.20.0.0/16"]
  location            = var.location
  resource_group_name = azurerm_resource_group.main.name

  tags = {
    owner       = var.owner_tag
    costCenter  = var.cost_center_tag
    environment = var.environment
  }
}

resource "azurerm_subnet" "project_subnet" {
  name                 = "snet-cost-governance-waste-detection"
  resource_group_name  = azurerm_resource_group.main.name
  virtual_network_name = azurerm_virtual_network.project_vnet.name
  address_prefixes     = ["10.20.1.0/24"]
}

# ---- Waste pattern 1: orphaned managed disk, attached to nothing ---

resource "azurerm_managed_disk" "orphaned_disk" {
  name                 = "disk-orphaned"
  location             = var.location
  resource_group_name  = azurerm_resource_group.main.name
  storage_account_type = "Standard_LRS"
  create_option        = "Empty"
  disk_size_gb         = 64

  tags = {
    owner       = var.owner_tag
    costCenter  = var.cost_center_tag
    environment = var.environment
    purpose     = "waste-demo-orphaned-disk"
  }
}

# ---- Waste pattern 2: unassociated public IP, attached to nothing ----
resource "azurerm_public_ip" "orphaned_public_ip" {
  name                = "pip-orphaned"
  location            = var.location
  resource_group_name = azurerm_resource_group.main.name
  allocation_method   = "Static"
  sku                 = "Standard"

  tags = {
    owner       = var.owner_tag
    costCenter  = var.cost_center_tag
    environment = var.environment
    purpose     = "waste-demo-orphaned-ip"
  }
}

# ---- Waste pattern 3: VM stopped but not deallocated (still billed)

resource "tls_private_key" "waste_vm_key" {
  algorithm = "RSA"
  rsa_bits  = 4096
}


resource "azurerm_network_interface" "waste_vm_nic" {
  name                = "nic-waste-demo-vm"
  location            = var.location
  resource_group_name = azurerm_resource_group.main.name

  ip_configuration {
    name                          = "internal"
    subnet_id                     = azurerm_subnet.project_subnet.id
    private_ip_address_allocation = "Dynamic"
  }

  tags = {
    owner       = var.owner_tag
    costCenter  = var.cost_center_tag
    environment = var.environment
  }
}

resource "azurerm_linux_virtual_machine" "waste_demo_vm" {
  name                = "vm-waste-demo-stopped"
  location            = var.location
  resource_group_name = azurerm_resource_group.main.name
  size                = "Standard_B2s_v2"
  admin_username      = var.admin_username

  network_interface_ids = [azurerm_network_interface.waste_vm_nic.id]

  disable_password_authentication = true

  admin_ssh_key {
    username   = var.admin_username
    public_key = tls_private_key.waste_vm_key.public_key_openssh
  }

  os_disk {
    caching              = "ReadWrite"
    storage_account_type = "Standard_LRS"
  }

  source_image_reference {
    publisher = "Canonical"
    offer     = "0001-com-ubuntu-server-jammy"
    sku       = "22_04-lts"
    version   = "latest"
  }

  tags = {
    owner       = var.owner_tag
    costCenter  = var.cost_center_tag
    environment = var.environment
    purpose     = "waste-demo-stopped-not-deallocated"
  }

}

# forces the specific "stopped" but not deallocated state 

resource "null_resource" "stop_without_deallocate" {
  depends_on = [azurerm_linux_virtual_machine.waste_demo_vm]

  provisioner "local-exec" {
    command = "az vm stop --resource-group ${azurerm_resource_group.main.name} --name ${azurerm_linux_virtual_machine.waste_demo_vm.name} --skip-shutdown"
  }
}