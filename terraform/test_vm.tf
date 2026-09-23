resource "azurerm_public_ip" "test_vm" {
  count = var.deploy_test_vm ? 1 : 0

  name                = "pip-vm-test"
  resource_group_name = azurerm_resource_group.primary.name
  location            = var.primary_location
  sku                 = "Standard"
  allocation_method   = "Static"
  tags                = var.tags
}

resource "azurerm_network_interface" "test_vm" {
  count = var.deploy_test_vm ? 1 : 0

  name                = "nic-vm-test"
  resource_group_name = azurerm_resource_group.primary.name
  location            = var.primary_location
  tags                = var.tags

  ip_configuration {
    name                          = "internal"
    subnet_id                     = azurerm_subnet.client.id
    private_ip_address_allocation = "Dynamic"
    public_ip_address_id          = azurerm_public_ip.test_vm[0].id
  }
}

resource "azurerm_linux_virtual_machine" "test_vm" {
  count = var.deploy_test_vm ? 1 : 0

  name                            = "vm-test"
  resource_group_name             = azurerm_resource_group.primary.name
  location                        = var.primary_location
  size                            = var.test_vm_size
  admin_username                  = var.test_vm_admin_username
  network_interface_ids           = [azurerm_network_interface.test_vm[0].id]
  disable_password_authentication = true
  tags                            = var.tags

  admin_ssh_key {
    username   = var.test_vm_admin_username
    public_key = var.test_vm_ssh_public_key
  }

  os_disk {
    caching              = "ReadWrite"
    storage_account_type = "Premium_LRS"
  }

  source_image_reference {
    publisher = "Canonical"
    offer     = "ubuntu-24_04-lts"
    sku       = "server"
    version   = "latest"
  }

  lifecycle {
    precondition {
      condition     = var.test_vm_ssh_public_key != ""
      error_message = "Set test_vm_ssh_public_key when deploy_test_vm is true."
    }
  }
}
