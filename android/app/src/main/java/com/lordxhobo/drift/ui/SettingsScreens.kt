package com.lordxhobo.drift.ui

import android.content.Context
import android.content.Intent
import android.graphics.BitmapFactory
import android.net.Uri
import android.os.PowerManager
import android.provider.Settings
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.PickVisualMediaRequest
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.KeyboardArrowRight
import androidx.compose.material.icons.filled.BatteryChargingFull
import androidx.compose.material.icons.filled.CheckCircle
import androidx.compose.material.icons.filled.Computer
import androidx.compose.material.icons.filled.Person
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.KeyboardCapitalization
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.lordxhobo.drift.BuildConfig
import com.lordxhobo.drift.social.ComputerLink
import com.lordxhobo.drift.social.Social
import com.lordxhobo.drift.social.UserProfile
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch

// MARK: Shared pieces

/** A profile picture, or a circle with the first letter. */
@Composable
fun Avatar(profile: UserProfile?, size: Dp, bytes: ByteArray? = profile?.avatar) {
    val bitmap = remember(bytes) { bytes?.let { runCatching { BitmapFactory.decodeByteArray(it, 0, it.size)?.asImageBitmap() }.getOrNull() } }
    Box(Modifier.size(size).clip(CircleShape).background(DriftColors.accent), contentAlignment = Alignment.Center) {
        when {
            bitmap != null -> Image(bitmap, contentDescription = null, contentScale = ContentScale.Crop, modifier = Modifier.size(size))
            profile != null -> Text(profile.name.take(1).uppercase(), color = DriftColors.onAccent, fontSize = (size.value * 0.42f).sp, fontWeight = FontWeight.Bold)
            else -> Icon(Icons.Filled.Person, contentDescription = null, tint = DriftColors.onAccent, modifier = Modifier.size(size * 0.55f))
        }
    }
}

@Composable
private fun Group(content: @Composable () -> Unit) {
    Column(
        Modifier.padding(horizontal = 16.dp).fillMaxWidth().clip(RoundedCornerShape(14.dp)).background(DriftColors.surface),
    ) { content() }
}

@Composable
private fun SettingsRow(
    title: String,
    subtitle: String? = null,
    icon: ImageVector? = null,
    iconColor: Color = DriftColors.accent,
    titleColor: Color = DriftColors.text,
    trailing: String? = null,
    onClick: () -> Unit,
) {
    Row(
        Modifier.fillMaxWidth().heightIn(min = 56.dp).clickable(onClick = onClick).padding(horizontal = 14.dp, vertical = 10.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        if (icon != null) {
            Box(Modifier.size(30.dp).clip(RoundedCornerShape(8.dp)).background(iconColor), contentAlignment = Alignment.Center) {
                Icon(icon, contentDescription = null, tint = Color.White, modifier = Modifier.size(18.dp))
            }
            Spacer(Modifier.width(12.dp))
        }
        Column(Modifier.weight(1f)) {
            Text(title, color = titleColor, fontSize = 15.sp, fontWeight = FontWeight.SemiBold)
            if (subtitle != null) Text(subtitle, color = DriftColors.muted, fontSize = 12.sp, modifier = Modifier.padding(top = 2.dp))
        }
        if (trailing != null) Text(trailing, color = DriftColors.muted, fontSize = 14.sp, modifier = Modifier.padding(start = 8.dp))
        Icon(Icons.AutoMirrored.Filled.KeyboardArrowRight, contentDescription = null, tint = DriftColors.muted)
    }
}

@Composable
private fun PageTitle(text: String) {
    Text(
        text, color = DriftColors.text, fontSize = 26.sp, fontWeight = FontWeight.ExtraBold,
        modifier = Modifier.padding(start = 16.dp, end = 16.dp, top = 4.dp, bottom = 16.dp),
    )
}

@Composable
private fun ErrorText(text: String) {
    Text(text, color = DriftColors.error, fontSize = 13.sp, fontWeight = FontWeight.SemiBold, modifier = Modifier.padding(top = 8.dp))
}

@Composable
private fun BigButton(text: String, enabled: Boolean = true, working: Boolean = false, onClick: () -> Unit) {
    Button(
        onClick = onClick,
        enabled = enabled && !working,
        colors = ButtonDefaults.buttonColors(containerColor = DriftColors.accent, contentColor = DriftColors.onAccent),
        modifier = Modifier.fillMaxWidth().heightIn(min = 50.dp),
    ) {
        if (working) {
            CircularProgressIndicator(color = DriftColors.onAccent, strokeWidth = 2.dp, modifier = Modifier.size(18.dp))
            Spacer(Modifier.width(10.dp))
        }
        Text(text, fontWeight = FontWeight.Bold, fontSize = 16.sp)
    }
}

private fun keepsPlaying(context: Context): Boolean {
    val power = context.getSystemService(Context.POWER_SERVICE) as PowerManager
    return power.isIgnoringBatteryOptimizations(context.packageName)
}

// MARK: Settings

@Composable
fun SettingsScreen() {
    val context = LocalContext.current
    val me = Social.me
    var allowed by remember { mutableStateOf(keepsPlaying(context)) }
    val battery = rememberLauncherForActivityResult(ActivityResultContracts.StartActivityForResult()) { allowed = keepsPlaying(context) }
    LazyColumn(contentPadding = PaddingValues(bottom = 24.dp)) {
        item { BackBar() }
        item { PageTitle("Settings") }
        // Your profile on top, like on the iPhone; it opens Profile & devices.
        item {
            Row(
                Modifier.padding(horizontal = 16.dp).fillMaxWidth().clip(RoundedCornerShape(14.dp)).background(DriftColors.surface)
                    .clickable { Nav.open(Screen.Account) }.padding(14.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Avatar(me, 48.dp)
                Spacer(Modifier.width(12.dp))
                Column(Modifier.weight(1f)) {
                    Text(me?.name ?: "Create a profile", color = DriftColors.text, fontSize = 16.sp, fontWeight = FontWeight.SemiBold)
                    Text(
                        if (me != null) "@${me.username} · Profile, link a computer" else "Sync your library and link a computer",
                        color = DriftColors.muted, fontSize = 12.sp, maxLines = 1, overflow = TextOverflow.Ellipsis,
                    )
                }
                Icon(Icons.AutoMirrored.Filled.KeyboardArrowRight, contentDescription = null, tint = DriftColors.muted)
            }
        }
        item { Spacer(Modifier.size(18.dp)) }
        item {
            Group {
                SettingsRow(
                    "Keep playing in the background",
                    if (allowed) "Drift may run with the screen off" else "Your phone may stop Drift to save battery",
                    icon = Icons.Filled.BatteryChargingFull,
                    iconColor = Color(0xFF2DD4BF),
                    trailing = if (allowed) "On" else "Off",
                ) {
                    val intent = if (allowed) Intent(Settings.ACTION_IGNORE_BATTERY_OPTIMIZATION_SETTINGS)
                    else Intent(Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS, Uri.parse("package:${context.packageName}"))
                    runCatching { battery.launch(intent) }.onFailure {
                        runCatching { battery.launch(Intent(Settings.ACTION_IGNORE_BATTERY_OPTIMIZATION_SETTINGS)) }
                    }
                }
            }
        }
        // More categories (Storage, Lyrics…) arrive with the features they hold.
        item {
            Text(
                "Drift ${BuildConfig.VERSION_NAME} for Android\nWhat's new",
                color = DriftColors.muted, fontSize = 12.sp, textAlign = TextAlign.Center,
                modifier = Modifier.fillMaxWidth().padding(top = 20.dp).clickable { UiState.showAllNotes = true }.padding(8.dp),
            )
        }
    }
}

// MARK: Profile & devices

@Composable
fun AccountScreen() {
    LazyColumn(contentPadding = PaddingValues(bottom = 24.dp)) {
        item { BackBar() }
        item { PageTitle("Profile & devices") }
        when {
            Social.status == Social.Status.LOADING && Social.me == null -> item {
                Box(Modifier.fillMaxWidth().padding(40.dp), contentAlignment = Alignment.Center) { CircularProgressIndicator(color = DriftColors.accent) }
            }
            Social.me == null -> item { CreateProfile() }
            else -> item { EditProfile(Social.me!!) }
        }
    }
}

/** Username availability, checked a moment after typing stops. */
@Composable
private fun rememberAvailability(name: String, current: String?): Pair<Boolean?, Boolean> {
    var available by remember { mutableStateOf<Boolean?>(null) }
    var checking by remember { mutableStateOf(false) }
    LaunchedEffect(name) {
        available = null
        if (name == current || Social.validate(name) != null) return@LaunchedEffect
        checking = true
        delay(400)
        available = Social.isAvailable(name)
        checking = false
    }
    return available to checking
}

@Composable
private fun UsernameHint(name: String, available: Boolean?, checking: Boolean) {
    val problem = if (name.isEmpty()) null else Social.validate(name)
    val (text, color) = when {
        name.isEmpty() -> Social.USERNAME_RULE to DriftColors.muted
        problem != null -> problem to DriftColors.error
        checking -> "Checking…" to DriftColors.muted
        available == true -> "@$name is free" to DriftColors.accent
        available == false -> "@$name is taken" to DriftColors.error
        else -> "Couldn't check right now" to DriftColors.muted
    }
    Text(text, color = color, fontSize = 12.sp, modifier = Modifier.padding(top = 4.dp, start = 4.dp))
}

@Composable
private fun CreateProfile() {
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    var username by remember { mutableStateOf("") }
    var display by remember { mutableStateOf("") }
    var photo by remember { mutableStateOf<ByteArray?>(null) }
    var working by remember { mutableStateOf(false) }
    var error by remember { mutableStateOf<String?>(null) }
    val (available, checking) = rememberAvailability(username, null)
    val picker = rememberLauncherForActivityResult(ActivityResultContracts.PickVisualMedia()) { uri ->
        if (uri != null) photo = Social.avatarData(context, uri)
    }
    Column(Modifier.padding(horizontal = 16.dp)) {
        Text(
            "A profile keeps your library in sync with Drift on a computer and your other phones. No email or password: it lives on this phone.",
            color = DriftColors.text2, fontSize = 14.sp,
        )
        Spacer(Modifier.size(18.dp))
        Column(Modifier.fillMaxWidth(), horizontalAlignment = Alignment.CenterHorizontally) {
            Box(Modifier.clickable { picker.launch(PickVisualMediaRequest(ActivityResultContracts.PickVisualMedia.ImageOnly)) }) {
                Avatar(null, 88.dp, photo)
            }
            Text(if (photo == null) "Add a photo" else "Change photo", color = DriftColors.accent, fontSize = 13.sp, fontWeight = FontWeight.SemiBold,
                modifier = Modifier.padding(top = 6.dp).clickable { picker.launch(PickVisualMediaRequest(ActivityResultContracts.PickVisualMedia.ImageOnly)) })
        }
        Spacer(Modifier.size(14.dp))
        OutlinedTextField(
            value = username,
            onValueChange = { username = Social.cleaned(it).take(20); error = null },
            label = { Text("Username") },
            prefix = { Text("@") },
            singleLine = true,
            keyboardOptions = KeyboardOptions(capitalization = KeyboardCapitalization.None, autoCorrectEnabled = false),
            modifier = Modifier.fillMaxWidth(),
        )
        UsernameHint(username, available, checking)
        Spacer(Modifier.size(10.dp))
        OutlinedTextField(
            value = display,
            onValueChange = { display = it.replace("\n", " ").take(Social.DISPLAY_NAME_LIMIT) },
            label = { Text("Name (optional)") },
            singleLine = true,
            modifier = Modifier.fillMaxWidth(),
        )
        Text("Shown to friends. Leave it empty to show your username.", color = DriftColors.muted, fontSize = 12.sp, modifier = Modifier.padding(top = 4.dp, start = 4.dp))
        error?.let { ErrorText(it) }
        Spacer(Modifier.size(18.dp))
        BigButton("Create profile", enabled = available == true, working = working) {
            working = true
            error = null
            scope.launch {
                try {
                    Social.createProfile(username, display, photo)
                } catch (e: Exception) {
                    error = e.message ?: "Couldn't create the profile."
                }
                working = false
            }
        }
    }
}

@Composable
private fun EditProfile(me: UserProfile) {
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    var editing by remember { mutableStateOf<String?>(null) } // "name", "username", "delete"
    var error by remember { mutableStateOf<String?>(null) }
    var working by remember { mutableStateOf(false) }
    val picker = rememberLauncherForActivityResult(ActivityResultContracts.PickVisualMedia()) { uri ->
        val data = uri?.let { Social.avatarData(context, it) } ?: return@rememberLauncherForActivityResult
        scope.launch {
            error = runCatching { Social.setPhoto(data) }.exceptionOrNull()?.message
        }
    }
    Column {
        Column(Modifier.fillMaxWidth(), horizontalAlignment = Alignment.CenterHorizontally) {
            Avatar(me, 96.dp)
            Text(me.name, color = DriftColors.text, fontSize = 22.sp, fontWeight = FontWeight.ExtraBold, modifier = Modifier.padding(top = 10.dp))
            Text("@${me.username}", color = DriftColors.muted, fontSize = 14.sp)
        }
        error?.let { Box(Modifier.padding(horizontal = 16.dp)) { ErrorText(it) } }
        Spacer(Modifier.size(18.dp))
        Group {
            SettingsRow("Name", me.displayName ?: "Not set: your username shows") { editing = "name" }
            SettingsRow("Username", "@${me.username}") { editing = "username" }
            SettingsRow("Photo", if (me.avatar64 != null) "Tap to change" else "Not set") {
                picker.launch(PickVisualMediaRequest(ActivityResultContracts.PickVisualMedia.ImageOnly))
            }
        }
        Spacer(Modifier.size(18.dp))
        Group {
            SettingsRow("Link a computer", "Use your library in Drift on a computer", icon = Icons.Filled.Computer, iconColor = Color(0xFFF5A524)) {
                Nav.open(Screen.LinkComputer)
            }
        }
        Text(
            "Your library starts syncing in the next update. Linking now already signs the computer in to this profile.",
            color = DriftColors.muted, fontSize = 12.sp, modifier = Modifier.padding(horizontal = 20.dp, vertical = 8.dp),
        )
        Spacer(Modifier.size(10.dp))
        Group {
            SettingsRow("Delete profile", titleColor = DriftColors.error) { editing = "delete" }
        }
    }

    when (editing) {
        "name" -> TextDialog("Name", me.displayName ?: "", "Leave it empty to show your username.", transform = { it.replace("\n", " ").take(Social.DISPLAY_NAME_LIMIT) },
            onDismiss = { editing = null }) { value, done ->
            scope.launch {
                try { Social.setDisplayName(value); done(null) } catch (e: Exception) { done(e.message ?: "Couldn't save the name.") }
            }
        }
        "username" -> UsernameDialog(me) { editing = null }
        "delete" -> AlertDialog(
            onDismissRequest = { if (!working) editing = null },
            title = { Text("Delete your profile?") },
            text = { Text("Your profile and username are removed from Drift. Songs and playlists on this phone stay. Linked computers stop syncing.") },
            confirmButton = {
                TextButton(enabled = !working, onClick = {
                    working = true
                    scope.launch {
                        error = runCatching { Social.deleteProfile() }.exceptionOrNull()?.message
                        working = false
                        editing = null
                    }
                }) { Text("Delete", color = DriftColors.error) }
            },
            dismissButton = { TextButton(enabled = !working, onClick = { editing = null }) { Text("Cancel") } },
            containerColor = DriftColors.surface,
        )
    }
}

/** A dialog with one text field. `save` reports back an error, or null when it's done. */
@Composable
private fun TextDialog(
    title: String,
    initial: String,
    hint: String,
    transform: (String) -> String,
    onDismiss: () -> Unit,
    save: (String, (String?) -> Unit) -> Unit,
) {
    var value by remember { mutableStateOf(initial) }
    var working by remember { mutableStateOf(false) }
    var error by remember { mutableStateOf<String?>(null) }
    AlertDialog(
        onDismissRequest = { if (!working) onDismiss() },
        title = { Text(title) },
        text = {
            Column {
                OutlinedTextField(value = value, onValueChange = { value = transform(it); error = null }, singleLine = true, modifier = Modifier.fillMaxWidth())
                Text(hint, color = DriftColors.muted, fontSize = 12.sp, modifier = Modifier.padding(top = 4.dp))
                error?.let { ErrorText(it) }
            }
        },
        confirmButton = {
            TextButton(enabled = !working, onClick = {
                working = true
                save(value) { problem ->
                    working = false
                    if (problem == null) onDismiss() else error = problem
                }
            }) { Text("Save") }
        },
        dismissButton = { TextButton(enabled = !working, onClick = onDismiss) { Text("Cancel") } },
        containerColor = DriftColors.surface,
    )
}

@Composable
private fun UsernameDialog(me: UserProfile, onDismiss: () -> Unit) {
    val scope = rememberCoroutineScope()
    var name by remember { mutableStateOf(me.username) }
    var working by remember { mutableStateOf(false) }
    var error by remember { mutableStateOf<String?>(null) }
    val (available, checking) = rememberAvailability(name, me.username)
    AlertDialog(
        onDismissRequest = { if (!working) onDismiss() },
        title = { Text("Username") },
        text = {
            Column {
                OutlinedTextField(
                    value = name,
                    onValueChange = { name = Social.cleaned(it).take(20); error = null },
                    prefix = { Text("@") },
                    singleLine = true,
                    keyboardOptions = KeyboardOptions(capitalization = KeyboardCapitalization.None, autoCorrectEnabled = false),
                    modifier = Modifier.fillMaxWidth(),
                )
                if (name != me.username) UsernameHint(name, available, checking)
                error?.let { ErrorText(it) }
            }
        },
        confirmButton = {
            TextButton(enabled = !working && (name == me.username || available == true), onClick = {
                if (name == me.username) {
                    onDismiss()
                    return@TextButton
                }
                working = true
                scope.launch {
                    try {
                        Social.changeUsername(name)
                        onDismiss()
                    } catch (e: Exception) {
                        error = e.message ?: "Couldn't change the username."
                    }
                    working = false
                }
            }) { Text("Save") }
        },
        dismissButton = { TextButton(enabled = !working, onClick = onDismiss) { Text("Cancel") } },
        containerColor = DriftColors.surface,
    )
}

// MARK: Link a computer

@Composable
fun LinkComputerScreen() {
    val scope = rememberCoroutineScope()
    var code by remember { mutableStateOf("") }
    var request by remember { mutableStateOf<ComputerLink.Request?>(null) }
    var working by remember { mutableStateOf(false) }
    var error by remember { mutableStateOf<String?>(null) }
    var done by remember { mutableStateOf(false) }
    val lookUp = {
        if (ComputerLink.normalize(code).length == 8 && !working) {
            working = true
            error = null
            scope.launch {
                try {
                    request = ComputerLink.lookUp(code)
                } catch (e: Exception) {
                    error = e.message ?: "Couldn't find that code."
                }
                working = false
            }
        }
    }
    LazyColumn(contentPadding = PaddingValues(bottom = 24.dp)) {
        item { BackBar() }
        item { PageTitle("Link a computer") }
        item {
            Column(Modifier.padding(horizontal = 16.dp), verticalArrangement = Arrangement.spacedBy(14.dp)) {
                val r = request
                when {
                    done -> {
                        Icon(Icons.Filled.CheckCircle, contentDescription = null, tint = DriftColors.accent, modifier = Modifier.size(44.dp))
                        Text("Linked", color = DriftColors.text, fontSize = 22.sp, fontWeight = FontWeight.ExtraBold)
                        Text("The computer is now signed in to your profile. To unlink, use Settings on the computer.", color = DriftColors.muted, fontSize = 14.sp)
                        BigButton("Done") { Nav.back() }
                    }
                    r != null -> {
                        Icon(Icons.Filled.Computer, contentDescription = null, tint = DriftColors.accent, modifier = Modifier.size(40.dp))
                        Text("Link ${r.device}?", color = DriftColors.text, fontSize = 22.sp, fontWeight = FontWeight.ExtraBold)
                        Text(
                            "It gets your Drift profile and library: playlists, albums, liked songs and followed artists, kept in sync both ways. Only link computers you use.",
                            color = DriftColors.muted, fontSize = 14.sp,
                        )
                        error?.let { ErrorText(it) }
                        BigButton("Link", working = working) {
                            working = true
                            error = null
                            scope.launch {
                                try {
                                    ComputerLink.link(r)
                                    done = true
                                } catch (e: Exception) {
                                    error = e.message ?: "Couldn't link the computer."
                                }
                                working = false
                            }
                        }
                        TextButton(onClick = { request = null; code = ""; error = null }, modifier = Modifier.fillMaxWidth()) {
                            Text("Use a different code", color = DriftColors.muted)
                        }
                    }
                    else -> {
                        Text(
                            "Open Drift on your computer, go to Settings → Phone & connections and choose Link your phone. Type the code it shows.",
                            color = DriftColors.text2, fontSize = 15.sp,
                        )
                        OutlinedTextField(
                            value = code,
                            onValueChange = { new ->
                                val c = ComputerLink.normalize(new)
                                code = if (c.length > 4) c.take(4) + "-" + c.drop(4) else c
                                error = null
                            },
                            placeholder = { Text("ABCD-EFGH", fontFamily = FontFamily.Monospace) },
                            textStyle = androidx.compose.ui.text.TextStyle(fontSize = 28.sp, fontWeight = FontWeight.Bold, fontFamily = FontFamily.Monospace, textAlign = TextAlign.Center, color = DriftColors.text),
                            singleLine = true,
                            keyboardOptions = KeyboardOptions(capitalization = KeyboardCapitalization.Characters, autoCorrectEnabled = false),
                            modifier = Modifier.fillMaxWidth(),
                        )
                        error?.let { ErrorText(it) }
                        BigButton("Next", enabled = ComputerLink.normalize(code).length == 8, working = working) { lookUp() }
                    }
                }
            }
        }
    }
}
