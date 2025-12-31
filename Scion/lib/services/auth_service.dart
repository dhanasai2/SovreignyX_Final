import 'dart:io';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../models/user.dart' as local_user;

class AuthService {
  static final AuthService _instance = AuthService._internal();
  factory AuthService() => _instance;
  AuthService._internal();

  SupabaseClient get _client => Supabase.instance.client;

  String? _token;
  local_user.User? _currentUser;

  String? get token => _token;
  local_user.User? get currentUser => _currentUser;

  // Initialize Supabase - Should be called in main.dart
  static Future<void> initialize() async {
    await Supabase.initialize(
      url: 'YOUR_SUPABASE_URL',
      anonKey:
          'YOUR_ANON_KEY',
    );
  }

  // Helper method to extract error message from response
  String _extractErrorMessage(dynamic error) {
    if (error == null) return 'Unknown error occurred';

    if (error is AuthException) {
      if (error.statusCode == '429' || error.message.contains('rate_limit')) {
        return 'Too many attempts. Please wait a moment before trying again.';
      }
      return error.message;
    }

    if (error is PostgrestException) {
      return error.message;
    }

    if (error is String) {
      return error;
    }

    if (error is Map<String, dynamic>) {
      if (error.containsKey('message')) return error['message'].toString();
      if (error.containsKey('error')) return error['error'].toString();
    }

    return error.toString();
  }

  // Register a new user
  Future<Map<String, dynamic>> register({
    required String username,
    required String email,
    required String password,
    required String firstName,
    required String lastName,
  }) async {
    try {
      final response = await _client.auth.signUp(
        email: email,
        password: password,
        data: {
          'first_name': firstName,
          'last_name': lastName,
          'username': username,
        },
      );

      if (response.user != null) {
        // Create user profile in users table
        await _client.from('users').insert({
          'id': response.user!.id,
          'email': email,
          'username': username,
          'first_name': firstName,
          'last_name': lastName,
          'created_at': DateTime.now().toIso8601String(),
        });

        _token = response.session?.accessToken;
        _currentUser = local_user.User(
          id: response.user!.id,
          username: username,
          email: email,
          firstName: firstName,
          lastName: lastName,
          isVerified: false,
          points: 0,
          createdAt: DateTime.now(),
          updatedAt: DateTime.now(),
        );

        return {
          'success': true,
          'data': {'user': response.user, 'session': response.session},
        };
      } else {
        return {'success': false, 'error': 'Failed to create user'};
      }
    } catch (e) {
      return {'success': false, 'error': _extractErrorMessage(e)};
    }
  }

  // Login with email and password
  Future<Map<String, dynamic>> login({
    required String email,
    required String password,
  }) async {
    try {
      final response = await _client.auth.signInWithPassword(
        email: email,
        password: password,
      );

      if (response.user != null) {
        // Fetch user profile
        final profileResponse =
            await _client
                .from('users')
                .select()
                .eq('id', response.user!.id)
                .single();

        _token = response.session?.accessToken;
        _currentUser = local_user.User(
          id: response.user!.id,
          username: profileResponse['username'] ?? email.split('@')[0],
          email: response.user!.email ?? '',
          firstName: profileResponse['first_name'] ?? '',
          lastName: profileResponse['last_name'] ?? '',
          isVerified: profileResponse['is_verified'] ?? false,
          isPrivate: profileResponse['is_private'] ?? false,
          points: profileResponse['points'] ?? 0,
          createdAt: DateTime.parse(
            profileResponse['created_at'] ?? DateTime.now().toIso8601String(),
          ),
          updatedAt: DateTime.parse(
            profileResponse['updated_at'] ?? DateTime.now().toIso8601String(),
          ),
        );

        return {
          'success': true,
          'data': {'user': response.user, 'session': response.session},
        };
      } else {
        return {'success': false, 'error': 'Invalid credentials'};
      }
    } catch (e) {
      return {'success': false, 'error': _extractErrorMessage(e)};
    }
  }

  // Google Sign-In using ID token
  Future<Map<String, dynamic>> googleSignIn({
    required String idToken,
    required String email,
    required String firstName,
    required String lastName,
    String? photoUrl,
  }) async {
    try {
      // Validate required parameters
      if (idToken.isEmpty) {
        return {'success': false, 'error': 'ID Token is required'};
      }
      if (email.isEmpty) {
        return {'success': false, 'error': 'Email is required'};
      }

      // Sign in with ID token
      final response = await _client.auth.signInWithIdToken(
        provider: OAuthProvider.google,
        idToken: idToken,
      );

      if (response.user != null) {
        // Check if user already exists in users table
        try {
          final existingUser =
              await _client
                  .from('users')
                  .select()
                  .eq('id', response.user!.id)
                  .single();

          // User exists.
          // We do NOT overwrite the profile picture here to preserve any custom picture the user may have uploaded.
          // Only update if the existing user has NO profile picture at all.
          final currentPic = existingUser['profile_picture_url'] as String?;
          if ((currentPic == null || currentPic.isEmpty) && photoUrl != null) {
            await _client
                .from('users')
                .update({'profile_picture_url': photoUrl})
                .eq('id', response.user!.id);
          }
        } catch (e) {
          // User doesn't exist, create new profile
          await _client.from('users').insert({
            'id': response.user!.id,
            'email': email,
            'username': email.split('@')[0],
            'first_name': firstName,
            'last_name': lastName,
            'profile_picture_url': photoUrl,
            'created_at': DateTime.now().toIso8601String(),
          });
        }

        _token = response.session?.accessToken;
        _currentUser = local_user.User(
          id: response.user!.id,
          username: email.split('@')[0],
          email: email,
          firstName: firstName,
          lastName: lastName,
          isVerified: true,
          points: 0, // Default to 0, ideally should fetch from DB if existing
          createdAt: DateTime.now(),
          updatedAt: DateTime.now(),
        );

        return {
          'success': true,
          'data': {'user': response.user, 'session': response.session},
        };
      } else {
        return {'success': false, 'error': 'Failed to sign in with Google'};
      }
    } catch (e) {
      return {'success': false, 'error': _extractErrorMessage(e)};
    }
  }

  // Alternative Google Sign-In with OAuth
  Future<Map<String, dynamic>> googleSignInWithOAuth() async {
    try {
      final response = await _client.auth.signInWithOAuth(
        OAuthProvider.google,
        redirectTo: 'io.supabase.flutterdemo://login-callback/',
      );

      // Listen for auth state changes
      _client.auth.onAuthStateChange.listen((data) {
        if (data.session?.user != null) {
          final user = data.session!.user;
          _token = data.session?.accessToken;
          _currentUser = local_user.User(
            id: user.id,
            username: user.email?.split('@')[0] ?? 'user',
            email: user.email ?? '',
            firstName: user.userMetadata?['first_name'] ?? '',
            lastName: user.userMetadata?['last_name'] ?? '',
            isVerified: true,
            isPrivate:
                false, // Default for OAuth if not in metadata? Or fetch from DB separately.
            points: 0,
            createdAt: DateTime.now(),
            updatedAt: DateTime.now(),
          );
        }
      });

      return {'success': true, 'provider': response};
    } catch (e) {
      return {'success': false, 'error': _extractErrorMessage(e)};
    }
  }

  // Logout
  Future<void> logout() async {
    try {
      await _client.auth.signOut();
    } catch (e) {
      print('Logout error: $e');
    }

    _token = null;
    _currentUser = null;
  }

  // Get current user profile
  Future<Map<String, dynamic>> getUserProfile() async {
    try {
      final user = _client.auth.currentUser;
      if (user == null) {
        return {'success': false, 'error': 'User not authenticated'};
      }

      final response =
          await _client.from('users').select().eq('id', user.id).single();

      _currentUser = local_user.User(
        id: user.id,
        username: response['username'] ?? user.email?.split('@')[0] ?? 'user',
        email: user.email ?? '',
        firstName: response['first_name'] ?? '',
        lastName: response['last_name'] ?? '',
        profilePicture:
            response['profile_picture_url'], // Map the profile picture
        isVerified: response['is_verified'] ?? false,
        isPrivate: response['is_private'] ?? false,
        points: response['points'] ?? 0,
        createdAt: DateTime.parse(
          response['created_at'] ?? DateTime.now().toIso8601String(),
        ),
        updatedAt: DateTime.parse(
          response['updated_at'] ?? DateTime.now().toIso8601String(),
        ),
      );

      return {'success': true, 'data': response};
    } catch (e) {
      return {'success': false, 'error': _extractErrorMessage(e)};
    }
  }

  // Update user profile with file upload support
  Future<Map<String, dynamic>> updateUserProfile({
    String? firstName,
    String? lastName,
    String? phone,
    String? bio,
    File? profilePicture,
    bool? isPrivate, // Added support
    String? githubLink,
    String? linkedinLink,
    String? portfolioLink,
  }) async {
    try {
      final user = _client.auth.currentUser;
      if (user == null) {
        return {'success': false, 'error': 'No user logged in'};
      }

      final Map<String, dynamic> updateData = {};
      if (firstName != null) updateData['first_name'] = firstName;
      if (lastName != null) updateData['last_name'] = lastName;
      if (phone != null) updateData['phone'] = phone;
      if (bio != null) updateData['bio'] = bio;
      if (isPrivate != null) updateData['is_private'] = isPrivate;
      if (githubLink != null) updateData['github_link'] = githubLink;
      if (linkedinLink != null) updateData['linkedin_link'] = linkedinLink;
      if (portfolioLink != null) updateData['portfolio_link'] = portfolioLink;

      // If profile picture provided, upload to storage first
      if (profilePicture != null) {
        final fileName =
            '${user.id}_${DateTime.now().millisecondsSinceEpoch}.jpg';
        // User confirmed: Bucket is 'publics', folder is 'profile_picture'
        final filePath = 'profile_picture/$fileName';

        await _client.storage
            .from('publics')
            .upload(
              filePath,
              profilePicture,
              fileOptions: const FileOptions(
                cacheControl: '3600',
                upsert: true,
              ),
            );

        final publicUrl = _client.storage
            .from('publics')
            .getPublicUrl(filePath);

        updateData['profile_picture_url'] = publicUrl;
      }

      // Update user profile
      await _client.from('users').update(updateData).eq('id', user.id);

      // Fetch updated profile
      final response =
          await _client.from('users').select().eq('id', user.id).single();

      _currentUser = local_user.User(
        id: user.id,
        username: response['username'] ?? user.email?.split('@')[0] ?? 'user',
        email: user.email ?? '',
        firstName: response['first_name'] ?? '',
        lastName: response['last_name'] ?? '',
        profilePicture:
            response['profile_picture_url'], // Map the profile picture from DB
        isVerified: response['is_verified'] ?? false,
        isPrivate: response['is_private'] ?? false,
        points: response['points'] ?? 0,
        createdAt: DateTime.parse(
          response['created_at'] ?? DateTime.now().toIso8601String(),
        ),
        updatedAt: DateTime.parse(
          response['updated_at'] ?? DateTime.now().toIso8601String(),
        ),
      );

      return {'success': true, 'data': response};
    } catch (e) {
      return {'success': false, 'error': _extractErrorMessage(e)};
    }
  }

  // Check if user is authenticated
  bool isAuthenticated() {
    return _client.auth.currentUser != null;
  }

  // Get current session
  Session? getCurrentSession() {
    return _client.auth.currentSession;
  }

  // Fetch dashboard stats
  Future<Map<String, dynamic>> getDashboardStats() async {
    try {
      final user = _client.auth.currentUser;
      if (user == null) {
        return {'success': false, 'error': 'No user logged in'};
      }

      int enrolledCourses = 0;
      int achievements = 0;
      int rank = 0; // Default rank
      int streak = 0;

      // Try to fetch enrolled courses count
      try {
        final enrollments = await _client
            .from('enrollments')
            .select('id')
            .eq('user_id', user.id);

        if (enrollments is List) {
          enrolledCourses = enrollments.length;
        }
      } catch (e) {
        // Table might not exist yet or other error
      }

      // Try to fetch achievements count
      try {
        final achievementsList = await _client
            .from('user_achievements')
            .select('id')
            .eq('user_id', user.id);

        if (achievementsList is List) {
          achievements = achievementsList.length;
        }
      } catch (e) {
        // Table might not exist yet
      }

      // Fetch rank and points from leaderboard view
      try {
        final leaderboardStats =
            await _client
                .from('leaderboard')
                .select('rank, points')
                .eq('user_id', user.id)
                .maybeSingle();

        if (leaderboardStats != null) {
          rank = leaderboardStats['rank'] as int? ?? 0;
          // We can also return points if needed
        }
      } catch (e) {
        // View might not exist yet
      }

      return {
        'success': true,
        'data': {
          'courses': enrolledCourses,
          'achievements': achievements,
          'rank': rank,
          'streak': streak,
        },
      };
    } catch (e) {
      return {'success': false, 'error': _extractErrorMessage(e)};
    }
  }

  // Fetch recent activity
  Future<Map<String, dynamic>> getRecentActivity() async {
    try {
      final user = _client.auth.currentUser;
      if (user == null) {
        return {'success': false, 'error': 'No user logged in'};
      }

      // Try to fetch from activity_log or notifications table
      // This is a common pattern. If table doesn't exist, we return empty list.
      try {
        final response = await _client
            .from('activity_log')
            .select()
            .eq('user_id', user.id)
            .order('created_at', ascending: false)
            .limit(5);

        return {'success': true, 'data': response};
      } catch (e) {
        return {'success': true, 'data': []}; // Return empty if table missing
      }
    } catch (e) {
      return {'success': false, 'error': _extractErrorMessage(e)};
    }
  }

  // Get all users
  Future<Map<String, dynamic>> getAllUsers() async {
    try {
      final response = await _client.from('users').select();
      return {'success': true, 'users': response};
    } catch (e) {
      return {'success': false, 'error': _extractErrorMessage(e)};
    }
  }

  // Get user profile by ID
  Future<Map<String, dynamic>> getUserProfileById(String userId) async {
    try {
      final response =
          await _client.from('users').select().eq('id', userId).single();
      return {'success': true, 'data': response};
    } catch (e) {
      return {'success': false, 'error': _extractErrorMessage(e)};
    }
  }
}
