import 'package:flutter/material.dart';

/// Cho phép các màn hình dùng camera tạm dừng camera khi có route khác phủ lên.
final RouteObserver<ModalRoute<dynamic>> appRouteObserver =
    RouteObserver<ModalRoute<dynamic>>();
