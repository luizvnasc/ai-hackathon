# Ensure Plane has an instance admin, the equivalent of GitLab's root user.
# Run inside the api container (stdin of `python manage.py shell`) by `make plane-admin`.
# Reads PLANE_ADMIN_EMAIL / PLANE_ADMIN_PASSWORD from the environment.
# Idempotent: it creates the user if missing, always resets the password to the
# value in infra/.env, makes the user an instance admin, and marks the
# instance setup as done so god-mode skips the sign-up screen.
import os
import uuid

from django.contrib.auth.hashers import make_password
from django.db import transaction
from django.utils import timezone

from plane.db.models import Profile, User
from plane.license.models import Instance, InstanceAdmin

email = os.environ["PLANE_ADMIN_EMAIL"].strip().lower()
password = os.environ["PLANE_ADMIN_PASSWORD"]

with transaction.atomic():
    instance = Instance.objects.select_for_update().first()
    if instance is None:
        raise SystemExit("Plane instance not registered yet; wait for the api container and retry")

    user = User.objects.filter(email=email).first()
    created = user is None
    if created:
        user = User.objects.create(
            first_name="root",
            email=email,
            username=uuid.uuid4().hex,
            password=make_password(password),
            is_password_autoset=False,
        )
        Profile.objects.get_or_create(user=user, defaults={"company_name": "ai-hackathon"})
    else:
        user.password = make_password(password)
        user.is_password_autoset = False
    user.is_active = True
    user.token_updated_at = timezone.now()
    user.save()

    InstanceAdmin.objects.get_or_create(user=user, instance=instance)
    if not instance.is_setup_done:
        instance.is_setup_done = True
        instance.instance_name = "ai-hackathon"
        instance.is_telemetry_enabled = False
        instance.save()

print(f"Plane admin {'created' if created else 'updated'}: {email}")
