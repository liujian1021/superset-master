PUBLIC_ROLE_LIKE = "Gamma"
ENABLE_GUEST_ROLE = True
SESSION_COOKIE_SAMESITE = None
SESSION_COOKIE_SECURE = True  # 如果你用的是 https
FEATURE_FLAGS = {
    "AG_GRID_TABLE": True,
}
print("✅ superset_config.py loaded")
