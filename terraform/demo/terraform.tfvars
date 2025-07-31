# terraform/demo/terraform.tfvars
aws_region    = "ap-southeast-1"
project_name  = "oracle-cdc-demo"
environment   = "demo"
owner_email   = "wasin.wangsombut@global.ntt"

# Database passwords
oracle_master_password   = "OracleDemo123!"
redshift_master_password = "RedshiftDemo123!"

# SSH public key for EC2 access (generate with: ssh-keygen -t rsa -b 4096)
ssh_public_key = "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAACAQCcxFqYfDyYCTWQQ5ILDvRP/qCbc4SQB087lx3/TdCINMXfGbayka+MAEnQFsSS5qKkMoVE3J7DPHiaZY3kNHJU0/lUYce4KR3XaTeQFXGVDUfohgJbdipI6HgqMi5yTC/TCahfrFl8Gu9cICkVDoTNn1ucw0Yny49a7IDsjGD7a+3HEvbosQNjZSNwy/LMg392/b66x8RdEmmV5XKKIwbel0jucjKxxYpIglkmRBZUYNJOtYCm5wKlH3JfQYVZ3kS9cbCV+OQItWYmB3S58wJdkcn91Lmlz3pZIIvznh/0w0eTP7aZ2b0xBuEPLSBn8RW4kjnpK667M7FNGLbU7PPQ06dC9OIHEgbF2DPAcojRkpTSQ1+z3ynC1oEHR5KcsavriqfK2OjDKeoL8qrZXKkMaX0cFBnRJHx71QnNXvRda4IvDH9HeZGMZbsfrwvhE1AJvWI+vcEXrC9S5RzEPX4MJ/efO4kvzlAJNl4PJpZqE9cYWLNC3j+7mz96a9iMOO+OJsEfXjckoRYLiYNmDm8AW3aMg+vesYEk8TiCr92FJ0MQFpA+nUsNYf3GaRzNEsyKiw4DS5IZlkp4QsuADK1xYIjvUD+Oy/7RbiuQEtCOc2xoibytBWjFtCKmS4i4VGXWkQNRKM/B+SUEuzM8Lk5Exsta6rPsb7RKibMiDQ+z1Q== AP+wasin.wangsombut@NTT-8D62R44"