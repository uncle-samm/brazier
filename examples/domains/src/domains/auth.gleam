/// Auth domain: user types for the multi-file example.
pub type User {
  User(name: String, email: String, role: Role)
}

pub type Role {
  Admin
  Member
  Guest
}

pub const roles = [Member, Admin, Guest]

pub fn role_label(role: Role) -> String {
  case role {
    Admin -> "Admin"
    Member -> "Member"
    Guest -> "Guest"
  }
}

/// The value of the role's `<option>`.
pub fn role_value(role: Role) -> String {
  case role {
    Admin -> "admin"
    Member -> "member"
    Guest -> "guest"
  }
}

pub fn parse_role(value: String) -> Result(Role, Nil) {
  case value {
    "admin" -> Ok(Admin)
    "member" -> Ok(Member)
    "guest" -> Ok(Guest)
    _ -> Error(Nil)
  }
}
